// Planet Ops Phase 4: the PDOS Drive worker against an in-memory Drive (FakeDrive) and a store that
// behaves as the database's claim/progress/result functions do (those are tested themselves in
// supabase/tests/planet_ops_job_costs_test.sql): folder sets made once, retries resuming, duplicate
// claims, partial failures, a bid summary moving into the job's folder with its Drive id kept.
import { describe, expect, it } from "vitest";
import { FakeDrive, runPdos, SUBFOLDERS, type FileClaim, type FolderClaim, type PdosConfig, type PdosStore } from "../src/services/pdos";

function setup() {
  const drive = new FakeDrive();
  const cfg: PdosConfig = { jobs_bid_folder_id: drive.root("Jobs Bid"), jobs_awarded_folder_id: drive.root("Jobs Awarded"), media_folder_id: drive.root("Media") };
  const folders = new Map<string, FolderClaim & { status: string }>();
  const files = new Map<string, FileClaim & { status: string; error?: string }>();
  const content = new Map<string, string>();
  const store: PdosStore = {
    async claim() {
      const f = [...folders.values()].filter((x) => x.status !== "done").map((x) => ({ ...x, steps: { ...x.steps } }));
      const done = (job: string | null) => job !== null && folders.get(job)?.status === "done";
      const due = [...files.values()].filter((x) => x.status !== "backed_up" && x.destination !== "held" && (x.destination === "jobs_bid" || done(x.job_id)));
      return {
        folders: f,
        files: due.map((x) => ({ ...x, folders: x.job_id ? { ...folders.get(x.job_id)?.steps } : null })),
      };
    },
    async folderProgress(job, steps, isDone, error) {
      const f = folders.get(job)!;
      Object.assign(f.steps, steps);
      if (isDone) f.status = "done";
      else if (error) f.status = "failed";
    },
    async fileResult(id, version, driveFileId, parent, error) {
      const f = files.get(id)!;
      if (error) Object.assign(f, { status: "failed", error });
      else Object.assign(f, { drive_file_id: driveFileId, drive_parent_id: parent, status: f.version > version ? "pending" : "backed_up" });
    },
    async config() { return cfg; },
    async content(file) { return { mime: "text/html", body: new TextEncoder().encode(content.get(file.source_id) ?? "") }; },
  };
  const job = (id: string, name: string) => folders.set(id, { job_id: id, company_id: "co", folder_name: name, steps: {}, status: "pending" });
  const file = (id: string, f: Partial<FileClaim>) => {
    files.set(id, { id, company_id: "co", source_kind: "estimate_summary", source_id: `src-${id}`, job_id: null, destination: "jobs_bid", file_name: `${id}.html`, version: 1, drive_file_id: null, drive_parent_id: null, folders: null, status: "pending", ...f });
    content.set(`src-${id}`, `<h1>${id}</h1>`);
  };
  return { drive, cfg, folders, files, store, job, file, run: () => runPdos(store, async () => drive) };
}

describe("PDOS Drive worker", () => {
  it("puts a bid's summary in Jobs Bid, then moves the same file into the job's Documents & Permits", async () => {
    const t = setup();
    t.file("sum", {});
    await t.run();
    const first = t.files.get("sum")!;
    expect(first.status).toBe("backed_up");
    expect(t.drive.childrenOf(t.cfg.jobs_bid_folder_id)).toEqual(["sum.html"]);
    expect(t.drive.childrenOf(t.cfg.jobs_awarded_folder_id)).toEqual([]);

    // The job is made: its folders, then the summary moves (a new version, same Drive file).
    t.job("job1", "12 Test Way - Garage Demo - 2026");
    Object.assign(first, { job_id: "job1", destination: "job_documents", version: 2, status: "pending" });
    await t.run();
    await t.run();
    const job = t.folders.get("job1")!;
    expect(job.status).toBe("done");
    expect(t.drive.childrenOf(t.cfg.jobs_awarded_folder_id)).toEqual(["12 Test Way - Garage Demo - 2026"]);
    expect(t.drive.childrenOf(job.steps.folder!)).toEqual([SUBFOLDERS.documents, SUBFOLDERS.dump_tickets, SUBFOLDERS.receipts].sort());
    expect(t.drive.childrenOf(t.cfg.media_folder_id)).toEqual(["12 Test Way - Garage Demo - 2026"]);
    expect(t.files.get("sum")!.drive_file_id).toBe(first.drive_file_id);
    expect(t.drive.childrenOf(t.cfg.jobs_bid_folder_id)).toEqual([]);
    expect(t.drive.childrenOf(job.steps.documents!)).toEqual(["sum.html"]);
  });

  it("a partial failure resumes the same folder set; nothing is made twice", async () => {
    const t = setup();
    t.job("job1", "5 Test Rd - House Demo - 2026");
    t.drive.failures.add("createFolder:3"); // the folder and Documents & Permits are made, then Reciepts fails
    const r1 = await t.run();
    expect(r1.failed).toBe(1);
    expect(t.folders.get("job1")!.status).toBe("failed");
    expect(Object.keys(t.folders.get("job1")!.steps).sort()).toEqual(["documents", "folder"]);
    await t.run();
    expect(t.folders.get("job1")!.status).toBe("done");
    expect(t.drive.childrenOf(t.cfg.jobs_awarded_folder_id)).toHaveLength(1);
    expect(t.drive.childrenOf(t.folders.get("job1")!.steps.folder!)).toHaveLength(3);
  });

  it("a folder made but not recorded (a timeout) is found by its job id, not made again", async () => {
    const t = setup();
    t.job("job1", "9 Test Ct - Barn Demo - 2026");
    await t.run();
    const made = t.folders.get("job1")!.steps.folder!;
    // The database lost the result (a crash after Drive answered): it claims the job again from scratch.
    Object.assign(t.folders.get("job1")!, { status: "pending", steps: {} });
    await t.run();
    expect(t.folders.get("job1")!.steps.folder).toBe(made);
    expect(t.drive.childrenOf(t.cfg.jobs_awarded_folder_id)).toHaveLength(1);
    expect(t.drive.childrenOf(t.cfg.media_folder_id)).toHaveLength(1);
  });

  it("a file copied but not recorded is found by its source, updated, not uploaded twice", async () => {
    const t = setup();
    t.file("sum", {});
    await t.run();
    Object.assign(t.files.get("sum")!, { status: "pending", drive_file_id: null, drive_parent_id: null, version: 2 });
    await t.run();
    expect(t.drive.childrenOf(t.cfg.jobs_bid_folder_id)).toEqual(["sum.html"]);
    expect(t.drive.calls.upload).toBe(1);
  });

  it("a failed copy is recorded and retried; a held file (no job yet) goes nowhere", async () => {
    const t = setup();
    t.file("sum", {});
    t.file("ticket", { source_kind: "cost_document", destination: "held" });
    t.drive.failures.add("upload:1");
    const r = await t.run();
    expect(r.failed).toBe(1);
    expect(t.files.get("sum")!.status).toBe("failed");
    expect(t.files.get("sum")!.error).toMatch(/503/);
    await t.run();
    expect(t.files.get("sum")!.status).toBe("backed_up");
    expect(t.files.get("ticket")!.status).toBe("pending");
    expect(t.drive.calls.upload).toBe(2);
  });

  it("does nothing for a business without PDOS set up, and says so", async () => {
    const t = setup();
    t.job("job1", "1 Test Ave - Demo - 2026");
    const r = await runPdos({ ...t.store, config: async () => null }, async () => t.drive);
    expect(r.skipped).toBe(1);
    expect(t.folders.get("job1")!.status).toBe("failed");
    expect(t.drive.childrenOf(t.cfg.jobs_awarded_folder_id)).toEqual([]);
  });
});

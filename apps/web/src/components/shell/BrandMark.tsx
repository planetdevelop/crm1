import { PRODUCT_NAME } from "@crewtavo/core/brand";

/**
 * The Planet Ops mark (same shapes as public/planet-ops-mark.svg).
 *
 * INTERIM: a plain planet-and-orbit placeholder in the brand colors (#1C50E4, #17801B), so the
 * modified version stops showing the Crewtavo logo (NOTICE section 7(e)). It is deliberately not a
 * redraw of the Planet Demolition crest: replace it with the approved crest artwork once supplied
 * (docs/PLANET_OPS_PROGRESS.md, "Pending owner inputs").
 */
export function BrandMark({ size = 28, className }: { size?: number; className?: string }) {
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 64 64" aria-hidden="true" focusable="false">
      <circle cx="32" cy="32" r="17" fill="#1C50E4" />
      <ellipse cx="32" cy="32" rx="29" ry="9.5" fill="none" stroke="#17801B" strokeWidth="4.5" transform="rotate(-24 32 32)" />
      <path d="M15 32a17 17 0 0 0 34 0" fill="#1C50E4" />
    </svg>
  );
}

/** Mark and name together, for the sidebar and sign-in pages. */
export function BrandLockup({ size = 28 }: { size?: number }) {
  return (
    <>
      <BrandMark size={size} />
      <span className="brand-name">{PRODUCT_NAME}</span>
    </>
  );
}

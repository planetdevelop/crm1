import { PRODUCT_NAME } from "@crewtavo/core/brand";

/**
 * Planet Ops brand artwork, from the approved logo (docs/brand/planet-ops-crest.png):
 *   - the mark: the orbital planet "O" cropped from the crest's wordmark, on a dark tile, for small
 *     sizes where the full crest isn't readable (sidebar, favicon, chat avatar, hub footer);
 *   - the crest: the full-color shield with "Planet Ops" on one line, for the sign-in pages.
 */
export function BrandMark({ size = 28, className }: { size?: number; className?: string }) {
  return <img className={className} src="/planet-ops-mark.png" width={size} height={size} alt="" aria-hidden="true" draggable={false} style={{ flex: "none" }} />;
}

/** The full crest. Its artwork already says "Planet Ops", so it carries the name for screen readers. */
export function BrandCrest({ width = 220, className }: { width?: number; className?: string }) {
  return <img className={className} src="/planet-ops-crest.webp" width={width} height={Math.round((width * 613) / 640)} alt={PRODUCT_NAME} draggable={false} style={{ display: "block", height: "auto", maxWidth: "100%" }} />;
}

/** Mark and name together, for the sidebar. */
export function BrandLockup({ size = 28 }: { size?: number }) {
  return (
    <>
      <BrandMark size={size} />
      <span className="brand-name">{PRODUCT_NAME}</span>
    </>
  );
}

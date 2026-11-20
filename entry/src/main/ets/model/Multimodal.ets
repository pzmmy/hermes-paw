// =====================================================================
// model/Multimodal.ets — S2-a image input: run input parts builder
// (pure functions, no IO; contract verified 2026-10-31 on the 236
//  live gateway, hermes v0.22.5 — s2_dataurl_test.py E2E)
//
// Contract (E2E-verified):
//   POST /v1/runs body.input = OpenAI-style MESSAGES array:
//   [{"role":"user","content":[{type:"text","text":...},
//     {type:"image_url","image_url":{"url":"data:<mime>;base64,<b64>"}}]}]
//   - a bare parts array is 400 "No user message found in input"
//     (_run_user_message takes input[-1]["content"])
//   - text-only runs keep the plain STRING input (M1, selftest W-02a)
//   - server staging (commit_api_images, source-verified 2026-10-31):
//     * data:image/{png,jpeg,gif,webp};base64 with REAL image bytes
//       (magic sniff) -> staged content-addressed
//     * data:image/* whose bytes are not a real image -> 400 invalid_params
//     * any other data URL (e.g. data:text/plain) is silently filtered
//       from the commit set and passed through to the model as-is (202)
//       — contract observation L2-06b; the client always emits
//       image/jpeg, so that path is defensive-only
//   - limits count AFTER the filter: 10 staged images/turn, 128MB total
//
// Server limits (session_api_media.py, source-verified 2026-10-31):
//   _IMAGE_LIMIT = 10 images/turn; max_inbound_media_bytes = 128MB total
// =====================================================================

/** Server per-turn image limit (source: _IMAGE_LIMIT=10). */
export const MM_MAX_IMAGES: number = 10;
/** Client pre-check: max raw image size worth reading. 20MB keeps a
 *  10-image turn far under the server's 128MB total cap. */
export const MM_MAX_RAW_BYTES: number = 20 * 1024 * 1024;
/** Client pre-check: max base64 length per image (≈37MB of image data). */
export const MM_MAX_B64_CHARS: number = 50 * 1024 * 1024;
/** Resize long edge (px): common vision-model effective resolution;
 *  saves traffic and tokens. 0 = no resize (never used in-app). */
export const MM_TARGET_LONG_EDGE: number = 1568;

/** text part (OpenAI vision shape). */
export function textPart(text: string): Record<string, Object> {
  let p: Record<string, Object> = {};
  p['type'] = 'text';
  p['text'] = text;
  return p;
}

/** image_url part carrying a data URL (mime embedded in the URL). */
export function imageUrlPart(dataUrl: string): Record<string, Object> {
  let url: Record<string, Object> = {};
  url['url'] = dataUrl;
  let p: Record<string, Object> = {};
  p['type'] = 'image_url';
  p['image_url'] = url;
  return p;
}

/**
 * Build the multimodal run input: [ {role:"user", content:[...]} ].
 * text may be '' (image-only turn); returns [] when dataUrls is empty
 * (the caller then keeps the plain-string input).
 */
export function buildUserMessage(text: string, dataUrls: string[]): Object[] {
  if (dataUrls.length === 0) {
    return [];
  }
  let content: Object[] = [];
  if (text !== '') {
    content.push(textPart(text));
  }
  for (let i = 0; i < dataUrls.length; i++) {
    content.push(imageUrlPart(dataUrls[i]));
  }
  let msg: Record<string, Object> = {};
  msg['role'] = 'user';
  msg['content'] = content;
  let out: Object[] = [];
  out.push(msg);
  return out;
}

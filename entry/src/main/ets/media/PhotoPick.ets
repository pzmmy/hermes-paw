// =====================================================================
// media/PhotoPick.ets — S2-a album pick + compress + base64 data URL
//
// System APIs only (zero third-party deps, §4.2):
//   @kit.MediaLibraryKit photoAccessHelper.PhotoViewPicker
//     — out-of-sandbox picker, NO permission declared (same pattern as
//       S1-a album QR decode, ScanVM.pickAlbum)
//   @kit.CoreFileKit fileIo — read the picker uri bytes
//   @kit.ImageKit image — decode at target size (desiredSize) + pack
//     JPEG via ImagePacker (ImageSource has no resize in current SDK)
//   @kit.ArkTS util.Base64Helper — base64 (sync)
//
// Pipeline: open(uri) -> size pre-check (MM_MAX_RAW_BYTES) -> read
//   ArrayBuffer -> createImageSource -> getImageInfo -> (optional)
//   createPixelMap(desiredSize) if long edge too big -> pack JPEG q80
//   -> base64 pre-check (MM_MAX_B64_CHARS) -> data:image/jpeg;base64,...
//
// Failure contract: prepareImage throws (Error pre-checks or a system
// BusinessError); ChatVM degrades per image (skip + notice) and keeps
// the pending row for retry.
// =====================================================================
import { Msg } from '../utils/Msg';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { MM_MAX_RAW_BYTES, MM_MAX_B64_CHARS, MM_TARGET_LONG_EDGE } from '../model/Multimodal';

const TAG: string = 'PhotoPick';
/** JPEG quality (0-100): 80 keeps detail while bounding the base64 size. */
const JPEG_QUALITY: number = 80;

/** One prepared image: original uri (thumbnails) + wire-ready data URL. */
export interface PreparedImage {
  uri: string;
  dataUrl: string;
  bytes: number;
}

/**
 * Open the system album picker (no permission). maxCount caps this
 * pick; ChatVM passes room = MM_MAX_IMAGES - pending count.
 * User cancellation throws (BusinessError) — caller treats it as
 * "nothing picked".
 */
export async function pickImages(maxCount: number): Promise<string[]> {
  let picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
  let options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = maxCount;
  let selectRes: photoAccessHelper.PhotoSelectResult = await picker.select(options);
  return selectRes.photoUris.slice();
}

/**
 * Prepare one album uri for the wire: read -> resize -> JPEG q80 ->
 * base64 data URL. Throws on any failure (human-readable message);
 * the file handle is always closed.
 */
export async function prepareImage(uri: string): Promise<PreparedImage> {
  let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    let stat: fileIo.Stat = fileIo.statSync(file.fd);
    if (stat.size === 0) {
      throw new Error(Msg.t('m_photo_empty'));
    }
    if (stat.size > MM_MAX_RAW_BYTES) {
      LogSafe.w(TAG, 'raw image too large: %{public}d bytes', stat.size);
      throw new Error(Msg.t('m_photo_exceed_prefix') + (MM_MAX_RAW_BYTES / 1024 / 1024) + Msg.t('m_photo_exceed_suffix'));
    }
    let buf: ArrayBuffer = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buf);
    let src: image.ImageSource = image.createImageSource(buf);
    let info: image.ImageInfo = await src.getImageInfo();
    let w: number = info.size.width;
    let h: number = info.size.height;
    let packer: image.ImagePacker = image.createImagePacker();
    let jpegBuf: ArrayBuffer;
    try {
      let packOpts: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
      let longEdge: number = Math.max(w, h);
      if (longEdge > 0 && longEdge > MM_TARGET_LONG_EDGE) {
        // Downscale during decode: ImageSource has no resize() in the
        // current SDK; DecodingOptions.desiredSize does the job.
        let scale: number = MM_TARGET_LONG_EDGE / longEdge;
        let tw: number = Math.max(1, Math.round(w * scale));
        let th: number = Math.max(1, Math.round(h * scale));
        let decodeOpts: image.DecodingOptions = { desiredSize: { width: tw, height: th } };
        let pixelMap: image.PixelMap = await src.createPixelMap(decodeOpts);
        try {
          jpegBuf = await packer.packing(pixelMap, packOpts);
        } finally {
          pixelMap.release();
        }
      } else {
        jpegBuf = await packer.packing(src, packOpts);
      }
    } finally {
      packer.release();
    }
    if (jpegBuf.byteLength > MM_MAX_RAW_BYTES) {
      LogSafe.w(TAG, 'compressed image still too large: %{public}d bytes', jpegBuf.byteLength);
      throw new Error(Msg.t('m_photo_compress_over'));
    }
    // encodeSync wants Uint8Array and returns the base64 chars as
    // Uint8Array (no util.Type in this SDK — single-arg call defaults
    // to base64); decodeToString (S1-proven name) yields the string.
    let b64Arr: Uint8Array = new util.Base64Helper().encodeSync(new Uint8Array(jpegBuf));
    let b64: string = util.TextDecoder.create('utf-8').decodeToString(b64Arr);
    if (b64.length > MM_MAX_B64_CHARS) {
      throw new Error(Msg.t('m_photo_data_too_large'));
    }
    let out: PreparedImage = {
      uri: uri,
      dataUrl: 'data:image/jpeg;base64,' + b64,
      bytes: jpegBuf.byteLength
    };
    LogSafe.d(TAG, 'image prepared: %dx%d -> %{public}d bytes jpeg', w, h, jpegBuf.byteLength);
    return out;
  } catch (err) {
    // Re-throw as Error: arkts-limited-throw only accepts Error
    // subclasses, and the caller reads .message for the notice text.
    let be: BusinessError = err as BusinessError;
    LogSafe.w(TAG, 'prepareImage failed: code=%{public}d message=%{public}s',
      Number(be.code), String(be.message));
    if (err instanceof Error) {
      throw err;
    }
    throw new Error(Msg.t('m_photo_process_fail') + String(be.message));
  } finally {
    fileIo.closeSync(file);
  }
}

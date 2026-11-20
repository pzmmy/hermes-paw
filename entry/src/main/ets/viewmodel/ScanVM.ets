// =====================================================================
// viewmodel/ScanVM.ets — QR setup flow (S1, plan §4.7 / m2-qr-design)
//
// Three input paths (all converge on parseSetupUri):
//   1. camera scan — scanBarcode.startScanForResult default UI
//      (system pre-authorized camera; no CAMERA permission declared)
//   2. album decode — PhotoViewPicker pick -> detectBarcode.decode
//      (no permission declared: the picker is an out-of-sandbox
//       system UI, same pattern as the Scan Kit default UI)
//   3. paste string — TextInput
// After parse: min_app gate (D6, best-effort; the probe below is the
// real gate) -> per-host probe (2s timeout; /health + /v1/models
// Bearer — same path shape as SettingsVM.probeServer: the pf
// prefix is applied by ApiClient.buildUrl) -> confirm card ->
// SettingsVM.importSetup.
// Four-cause diagnostics (m2-qr-design):
//   不可达(2s 超时) / 无应答(HTTP 0) / profile 不存在(404) / key 错误(401)
// Key material never reaches logs; probe failures only carry codes.
// =====================================================================
import { Msg } from '../utils/Msg';
import { common, bundleManager, abilityAccessCtrl } from '@kit.AbilityKit';
import { scanBarcode, detectBarcode, scanCore } from '@kit.ScanKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { ApiClient, ApiError, HttpResult } from '../net/ApiClient';
import { SetupUri, SetupParseResult, parseSetupUri, checkMinApp } from '../model/SetupUri';
import { SettingsVM } from './SettingsVM';

const TAG: string = 'ScanVM';
/** Probe timeout per host (m2-qr-design: 2s). */
const PROBE_TIMEOUT_MS: number = 2000;

/** One host's probe outcome (confirm card row). */
export class ProbeResult {
  host: string = '';
  /** true = /health 200 AND /v1/models 200 (authenticated) */
  ok: boolean = false;
  /** true = /health 200 (reachable) but auth/profile check failed */
  reachable: boolean = false;
  /** diagnostic: 认证通过 | 不可达（2s 超时） | 无应答 | profile 不存在（404） | key 错误（401） | HTTP <code> */
  detail: string = '';
}

export class ScanVM {
  /** idle | parsing | probing | confirm | saving | done */
  stage: string = 'idle';
  uri: SetupUri | null = null;
  probes: ProbeResult[] = [];
  busy: boolean = false;
  error: string = '';
  notice: string = '';

  private ctx: common.UIAbilityContext;
  private svm: SettingsVM;

  constructor(ctx: common.UIAbilityContext, svm: SettingsVM) {
    this.ctx = ctx;
    this.svm = svm;
  }

  /** Reset transient state (page entry / cancel). */
  reset(): void {
    this.stage = 'idle';
    this.uri = null;
    this.probes = [];
    this.error = '';
    this.notice = '';
  }

  /** Input 1: camera scan (Scan Kit default UI). */
  async startScan(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    this.notice = '';
    try {
      // ohos.permission.CAMERA is user_grant: ask at runtime before
      // launching the system scan UI (declared in module.json5).
      let atMgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // PermissionRequestResult is not exported by name in this SDK;
      // infer the result type from requestPermissionsFromUser instead.
      let grant = await atMgr.requestPermissionsFromUser(this.ctx, ['ohos.permission.CAMERA']);
      if (grant.authResults.length === 0 || grant.authResults[0] !== 0) {
        this.error = Msg.t('m_scan_camera_perm');
        return;
      }
      let opts: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: false
      };
      let result: scanBarcode.ScanResult =
        await scanBarcode.startScanForResult(this.ctx, opts);
      await this.afterRaw(result.originalValue);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      // User cancellation surfaces as an error code; hint only.
      LogSafe.i(TAG, 'scan cancelled/failed: code=%{public}d', Number(e.code));
      this.error = Msg.t('m_scan_cancelled');
    } finally {
      this.busy = false;
    }
  }

  /** Input 2: pick an image from the album and decode it. */
  async pickAlbum(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    this.notice = '';
    try {
      let picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      let options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      let selectRes: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (selectRes.photoUris.length === 0) {
        this.error = Msg.t('m_vm_no_image');
        return;
      }
      let input: detectBarcode.InputImage = { uri: selectRes.photoUris[0] };
      let opts: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: true,
        enableAlbum: true
      };
      let results: Array<scanBarcode.ScanResult> =
        await detectBarcode.decode(input, opts);
      if (results.length === 0) {
        this.error = Msg.t('m_scan_no_qr');
        return;
      }
      await this.afterRaw(results[0].originalValue);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.i(TAG, 'album decode cancelled/failed: code=%{public}d', Number(e.code));
      this.error = Msg.t('m_scan_gallery_fail');
    } finally {
      this.busy = false;
    }
  }

  /** Input 3: pasted string (from clipboard / chat). */
  async paste(text: string): Promise<void> {
    if (this.busy) {
      return;
    }
    if (text.trim() === '') {
      this.error = Msg.t('m_scan_paste_first');
      return;
    }
    this.busy = true;
    this.error = '';
    this.notice = '';
    try {
      await this.afterRaw(text);
    } finally {
      this.busy = false;
    }
  }

  /** Parse -> min_app gate -> probe all hosts -> confirm stage. */
  private async afterRaw(raw: string): Promise<void> {
    this.stage = 'parsing';
    this.error = '';
    let res: SetupParseResult = parseSetupUri(raw);
    if (res.uri === null) {
      this.stage = 'idle';
      this.error = res.error;
      return;
    }
    this.uri = res.uri;
    // D6: min_app gate, best-effort (bundle info unavailable on a
    // rare device -> probe below is the real gate)
    try {
      let info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      if (!checkMinApp(res.uri.minApp, info.versionName)) {
        this.stage = 'idle';
        this.error = Msg.t('m_scan_needs_version_prefix') + res.uri.minApp +
          Msg.t('m_scan_current_prefix') + info.versionName + Msg.t('m_scan_needs_version_suffix');
        return;
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'getBundleInfoForSelf failed: code=%{public}d', Number(e.code));
    }
    await this.probeAll();
  }

  private async probeAll(): Promise<void> {
    let u: SetupUri | null = this.uri;
    if (u === null) {
      this.stage = 'idle';
      return;
    }
    this.stage = 'probing';
    this.error = '';
    this.notice = '';
    let out: ProbeResult[] = [];
    for (let i: number = 0; i < u.hosts.length; i++) {
      out.push(await this.probeHost(u, u.hosts[i]));
    }
    // fresh array -> ForEach re-diffs on assignment
    this.probes = out;
    let anyOk: boolean = false;
    for (let i: number = 0; i < out.length; i++) {
      if (out[i].ok) {
        anyOk = true;
        break;
      }
    }
    this.stage = 'confirm';
    this.notice = anyOk ? '' : Msg.t('m_scan_no_usable');
  }

  private async probeHost(u: SetupUri, host: string): Promise<ProbeResult> {
    let pr: ProbeResult = new ProbeResult();
    pr.host = host;
    let c: ApiClient = new ApiClient();
    c.configure('http://' + host, u.key, 'default', u.pf);
    try {
      let r: HttpResult = await c.request(
        http.RequestMethod.GET, '/health', undefined, PROBE_TIMEOUT_MS, true);
      pr.reachable = true;
      if (r.code >= 200 && r.code < 300) {
        // stage 2: authenticated data plane
        let m: HttpResult = await c.request(
          http.RequestMethod.GET, '/v1/models', undefined, PROBE_TIMEOUT_MS, true);
        if (m.code >= 200 && m.code < 300) {
          pr.ok = true;
          pr.detail = Msg.t('m_scan_auth_ok');
        } else {
          pr.detail = this.diagnose(m.code);
        }
      } else {
        pr.detail = this.diagnose(r.code);
      }
    } catch (err) {
      if (err instanceof ApiError) {
        let e: ApiError = err as ApiError;
        pr.detail = e.code > 0 ? this.diagnose(e.code) : Msg.t('m_scan_unreachable_2s');
      } else {
        let e2: Error = err as Error;
        pr.detail = Msg.t('m_scan_no_reply_prefix') + e2.message;
      }
    }
    return pr;
  }

  private diagnose(code: number): string {
    if (code === 401) {
      return Msg.t('m_scan_bad_key');
    }
    if (code === 404) {
      return Msg.t('m_scan_no_profile');
    }
    if (code === 0) {
      return Msg.t('m_scan_no_reply');
    }
    return 'HTTP ' + String(code);
  }

  /** Save the chosen host: import profile + key, activate it. */
  async confirm(host: string): Promise<boolean> {
    let u: SetupUri | null = this.uri;
    if (u === null || this.busy) {
      return false;
    }
    this.busy = true;
    this.stage = 'saving';
    this.error = '';
    this.notice = '';
    let ok: boolean = await this.svm.importSetup(u, host);
    if (ok) {
      this.stage = 'done';
      this.notice = Msg.t('m_scan_imported') + u.name;
    } else {
      this.stage = 'confirm';
      this.error = this.svm.error !== '' ? this.svm.error : Msg.t('m_scan_import_fail');
    }
    this.busy = false;
    return ok;
  }
}

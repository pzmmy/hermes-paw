// =====================================================================
// net/JobsApi.ets — GET /api/jobs（定时任务列表，Conduit 借鉴）
//
// 236 网关实证（2026-11-17）：/api/jobs 返回 2 个定时任务
// （社区周报 + skill 安全审计），字段含 id/name/schedule/next_run_at/
// last_status/enabled 等。本 API 解析为精简 DTO 供设置页展示。
// =====================================================================

import { http } from '@kit.NetworkKit';
import { ApiClient, ApiError, HttpResult } from './ApiClient';

/** 定时任务精简 DTO（只取 UI 展示需要的字段）。 */
export interface JobInfo {
  id: string;
  name: string;
  /** cron 表达式（如 "0 8 * * 1"）。 */
  schedule: string;
  /** 下次执行时间 ISO 8601（如 "2026-11-23T08:00:00+08:00"）。 */
  nextRunAt: string;
  /** 上次执行状态（ok / failed / null）。 */
  lastStatus: string;
  /** 是否启用。 */
  enabled: boolean;
}

export class JobsApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  /** GET /api/jobs → 定时任务列表（容错：404/空 → 空数组）。 */
  async listJobs(): Promise<JobInfo[]> {
    let r: HttpResult;
    try {
      r = await this.client.request(http.RequestMethod.GET, '/api/jobs');
    } catch (err) {
      // 网关可能无 /api/jobs（老版本）→ 静默返回空数组
      let e: Error = err as Error;
      if (e instanceof ApiError) {
        let ae: ApiError = e as ApiError;
        if (ae.code === 404 || ae.code === 0) {
          return [];
        }
        throw new ApiError(ae.code, 'listJobs failed: ' + e.message, '');
      }
      throw new Error(e.message);
    }
    let out: JobInfo[] = [];
    try {
      let d: Record<string, Object> = JSON.parse(r.body);
      let jobs: Object | null | undefined = d['jobs'];
      if (jobs === null || jobs === undefined || !(jobs instanceof Array)) {
        return out;
      }
      let raw: Record<string, Object>[] = jobs as Record<string, Object>[];
      for (let i: number = 0; i < raw.length; i++) {
        let j: Record<string, Object> = raw[i];
        let info: JobInfo = {
          id: String(j['id'] ?? ''),
          name: String(j['name'] ?? ''),
          schedule: '',
          nextRunAt: '',
          lastStatus: '',
          enabled: true
        };
        let sched: Object | null | undefined = j['schedule'];
        if (sched !== null && sched !== undefined && sched instanceof Object) {
          let sm: Record<string, Object> = sched as Record<string, Object>;
          info.schedule = String(sm['display'] ?? sm['expr'] ?? '');
        }
        info.nextRunAt = String(j['next_run_at'] ?? '');
        let ls: Object | null | undefined = j['last_status'];
        if (ls !== null && ls !== undefined) {
          info.lastStatus = String(ls);
        }
        let en: Object | null | undefined = j['enabled'];
        if (en !== null && en !== undefined) {
          info.enabled = en === true;
        }
        out.push(info);
      }
    } catch (err) {
      // 解析失败静默返回已解析的部分
    }
    return out;
  }
}

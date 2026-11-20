// =====================================================================
// model/LocalSession.ets — local session row (M1, plan §4.5)
//
// Composite primary key (S1, plan §4.7 P1-2):
//   pk = serverId|pf|role|sessionId
//   serverId = baseUrl host:port (see ServerProfile.serverId)
//   pf       = profile prefix ('' = gateway default scope; the QR
//              payload value 'default' normalizes to '')
//   role     = session role header (X-Hermes-Session-Key)
//   pf and role are ORTHOGONAL: pf = URL scope (/p/<pf>/),
//   role = session-key header. M1 3-tuple rows migrate in place
//   (DbHelper v1->v2): legacy pk serverId|role|sessionId becomes
//   serverId|''|role|sessionId.
//   Cross-gateway session_id never collide (different serverId/pf/role)
// =====================================================================

export class LocalSession {
  /** composite pk: serverId|pf|role|sessionId (built via buildLocalPk) */
  pk: string = '';
  serverId: string = '';
  /** profile prefix ('' = no /p/ prefix) */
  pf: string = '';
  role: string = '';
  /** server session id (POST /api/sessions response session.id) */
  sessionId: string = '';
  /** display title (first user message, truncated by DbHelper) */
  title: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
}

/** Normalize a profile prefix: 'default' -> '' (no /p/ prefix). */
export function normPf(pf: string): string {
  return pf === 'default' ? '' : pf;
}

/** Build the composite 4-tuple pk: serverId|pf|role|sessionId (S1). */
export function buildLocalPk(serverId: string, pf: string, role: string,
  sessionId: string): string {
  return serverId + '|' + normPf(pf) + '|' + role + '|' + sessionId;
}

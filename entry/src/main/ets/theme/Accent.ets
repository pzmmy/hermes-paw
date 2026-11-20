// =====================================================================
// theme/Accent.ets — global accent (theme) color.
//
// A small set of preset accents (primary + light tint). The chosen index
// is persisted in Preferences (the same store pattern TokenVault uses)
// and applied on cold start — the same semantics as the in-app language
// switch: a change takes effect on the next launch. EntryAbility seeds
// the in-memory value before the UI loads, so the first paint already
// uses the saved accent (no race).
//
// Structural colors live in resources/base/element/color.json; the accent
// is the only dynamic (non-resource) color in the app.
// =====================================================================
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogSafe } from '../utils/LogSafe';

const TAG: string = 'Accent';
const PREF_NAME: string = 'hermes_paw_ui';
const KEY_INDEX: string = 'accent_index';

export interface AccentPreset {
  primary: string;
  tint: string;
}

/** Six preset accents. Order is stable — the persisted index addresses
 *  into this array; the display name is i18n'd on the Settings page. */
export const ACCENT_PRESETS: AccentPreset[] = [
  { primary: '#1E88E5', tint: '#E3F2FD' },
  { primary: '#00838F', tint: '#E0F7FA' },
  { primary: '#6A1B9A', tint: '#F3E5F5' },
  { primary: '#C2185B', tint: '#FCE4EC' },
  { primary: '#283593', tint: '#E8EAF6' },
  { primary: '#2E7D32', tint: '#E8F5E9' }
];

let currentIdx: number = 0;

export function accentPresetAt(index: number): AccentPreset {
  if (index < 0 || index >= ACCENT_PRESETS.length) {
    return ACCENT_PRESETS[0];
  }
  return ACCENT_PRESETS[index];
}

export function accentPrimary(): string {
  return accentPresetAt(currentIdx).primary;
}

export function accentTint(): string {
  return accentPresetAt(currentIdx).tint;
}

/** Read + clamp a raw stored value to a valid preset index. */
function clampIndex(v: preferences.ValueType): number {
  let n: number = (typeof v === 'number') ? (v as number) : 0;
  if (n < 0 || n >= ACCENT_PRESETS.length) {
    return 0;
  }
  return n;
}

/** Seed the in-memory accent from Preferences. Resolves ALWAYS (never
 *  rejects) so EntryAbility can proceed to loadContent even on failure
 *  (the accent then stays at its safe default, index 0). */
export async function accentInit(ctx: common.UIAbilityContext): Promise<void> {
  try {
    let pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    let v: preferences.ValueType = await pref.get(KEY_INDEX, 0);
    currentIdx = clampIndex(v);
  } catch (err) {
    let e: Error = err as Error;
    LogSafe.w(TAG, 'accentInit failed: %{public}s', e.message);
    // leave currentIdx at its default (0) — a safe fallback
  }
}

/** The saved (pending) accent index, for the Settings checkmark. */
export async function accentSavedIndex(ctx: common.UIAbilityContext): Promise<number> {
  try {
    let pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    let v: preferences.ValueType = await pref.get(KEY_INDEX, 0);
    return clampIndex(v);
  } catch (err) {
    let e: Error = err as Error;
    LogSafe.w(TAG, 'accentSavedIndex failed: %{public}s', e.message);
    return 0;
  }
}

/** Persist the chosen index. Cold-start semantics: applies on next launch. */
export async function accentSave(ctx: common.UIAbilityContext, index: number): Promise<void> {
  let clamped: number = (index < 0 || index >= ACCENT_PRESETS.length) ? 0 : index;
  try {
    let pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    await pref.put(KEY_INDEX, clamped);
    await pref.flush();
  } catch (err) {
    let e: Error = err as Error;
    LogSafe.w(TAG, 'accentSave failed: %{public}s', e.message);
  }
}

import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';

const TAG: string = 'OpenHarmonyTestRunner';
const DOMAIN: number = 0xFF02;

let abilityDelegatorInstance: abilityDelegatorRegistry.AbilityDelegator | undefined = undefined;

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(DOMAIN, TAG, 'TestRunner onPrepare');
  }

  async onRun(): Promise<void> {
    abilityDelegatorInstance = abilityDelegatorRegistry.getAbilityDelegator();
    const args: abilityDelegatorRegistry.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
    const testAbilityName: string = args.parameters['-Dability'] ?? 'TestAbility';
    hilog.info(DOMAIN, TAG, `TestRunner launching ability=${testAbilityName}`);
    const want: Want = {
      bundleName: 'com.pzmmy.hermespaw',
      abilityName: testAbilityName
    };
    await abilityDelegatorInstance.startAbility(want);
  }
}

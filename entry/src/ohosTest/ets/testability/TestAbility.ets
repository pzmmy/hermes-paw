import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

const ON_DESTROY_ERROR = -2;

export default class TestAbility extends UIAbility {
  abilityDelegator: abilityDelegatorRegistry.AbilityDelegator;

  constructor() {
    super();
    this.abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onCreate');
    let abilityDelegatorArguments: abilityDelegatorRegistry.AbilityDelegatorArgs;
    abilityDelegatorArguments = abilityDelegatorRegistry.getArguments();
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'start run testcase!!!');
    // 真正触发 hypium 执行测试套件的入口（不是 loadContent 页面）。
    Hypium.hypiumTest(this.abilityDelegator, abilityDelegatorArguments, testsuite);
  }

  onDestroy() {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onDestroy');
    this.abilityDelegator.finishTest('TestAbility onDestroy unexpectedly!', ON_DESTROY_ERROR, () => {});
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onWindowStageCreate');
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'TestAbility', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'TestAbility', '%{public}s', 'Content loaded successfully.');
    });
  }

  onWindowStageDestroy() {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onWindowStageDestroy');
  }

  onForeground() {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onForeground');
  }

  onBackground() {
    hilog.info(0x0000, 'TestAbility', '%{public}s', 'TestAbility onBackground');
  }
}

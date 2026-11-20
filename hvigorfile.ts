// Root build script (hvigor 6.x; verified: hvigorw 6.26.8 by the main control on 2026-10-27)
import { appTasks } from '@ohos/hvigor-ohos-plugin';

export default {
  system: appTasks, // Built-in hvigor tasks for the app
  plugins: []       // No additional plugins (zero third-party dependencies)
};

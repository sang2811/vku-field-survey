import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'edu.vku.fieldsurvey',
  appName: 'VKU Field Survey',
  webDir: 'build/web',
  bundledWebRuntime: false,
  plugins: {
    Camera: {
      permissions: ['camera', 'photos']
    },
    Geolocation: {
      permissions: ['location']
    }
  },
  android: {
    allowMixedContent: false
  }
};

export default config;

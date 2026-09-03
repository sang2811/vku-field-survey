(function () {
  async function getPosition() {
    const capacitor = window.Capacitor;
    const plugins = capacitor && capacitor.Plugins ? capacitor.Plugins : {};

    if (plugins.Geolocation) {
      const position = await plugins.Geolocation.getCurrentPosition({
        enableHighAccuracy: true,
        timeout: 12000
      });
      return {
        latitude: position.coords.latitude,
        longitude: position.coords.longitude,
        accuracy: position.coords.accuracy || null,
        source: 'capacitor'
      };
    }

    if (!navigator.geolocation) {
      throw new Error('GPS is not available on this device.');
    }

    return new Promise(function (resolve, reject) {
      navigator.geolocation.getCurrentPosition(function (position) {
        resolve({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          accuracy: position.coords.accuracy || null,
          source: 'browser'
        });
      }, reject, {
        enableHighAccuracy: true,
        timeout: 12000
      });
    });
  }

  async function takePhoto() {
    const capacitor = window.Capacitor;
    const plugins = capacitor && capacitor.Plugins ? capacitor.Plugins : {};

    if (plugins.Camera) {
      const image = await plugins.Camera.getPhoto({
        quality: 78,
        allowEditing: false,
        resultType: 'dataUrl',
        source: 'CAMERA'
      });
      return {
        dataUrl: image.dataUrl,
        source: 'capacitor'
      };
    }

    return new Promise(function (resolve, reject) {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = 'image/*';
      input.capture = 'environment';
      input.onchange = function () {
        const file = input.files && input.files[0];
        if (!file) {
          reject(new Error('No photo selected.'));
          return;
        }
        const reader = new FileReader();
        reader.onload = function () {
          resolve({
            dataUrl: reader.result,
            source: 'browser'
          });
        };
        reader.onerror = reject;
        reader.readAsDataURL(file);
      };
      input.click();
    });
  }

  window.CapacitorSurvey = {
    getPosition: getPosition,
    takePhoto: takePhoto
  };
})();

'use strict';

const preview = document.querySelector('#app-preview');
const currentImg = document.querySelector('#screen-shot');
const nextImg = document.querySelector('#screen-shot-next');
const screenDesc = document.querySelector('#screen-description');
const screenButtons = Array.from(document.querySelectorAll('[data-screen][aria-pressed]'));

const screenCatalog = {
  windows: {
    src: 'assets/windows-interface.png',
    width: 1086,
    height: 693,
    title: 'Windows Desktop Radar.',
    desc: 'Toggle Discoverable, pick your download folder, and spot nearby devices cleanly on a calm midnight radar.',
    alt: 'Daphq Windows desktop app showing a nearby Android phone on the Orbital Radar',
    ariaLabel: 'Real Windows desktop screenshot of the Daphq app',
  },
  android: {
    src: 'assets/android-interface.png',
    width: 1390,
    height: 2894,
    title: 'Android Companion App.',
    desc: 'Background Foreground Service keeps multi-gigabyte transfers moving even when your phone screen locks.',
    alt: 'Daphq Android app showing Omar-PC on the Orbital Radar',
    ariaLabel: 'Real Android app screenshot of Daphq',
  },
  demo: {
    src: 'assets/Demo.gif',
    width: 1280,
    height: 720,
    title: 'Live Transfer In Action.',
    desc: 'Select files or whole folders, approve on the receiver once, and watch files fly across local Wi-Fi.',
    alt: 'Animated recording of Daphq transferring files between Windows and Android',
    ariaLabel: 'Live transfer demo recording of Daphq',
  },
};

// Prewarm showcase previews in browser memory.
const preloadedScreens = new Map();
Object.entries(screenCatalog).forEach(([key, entry]) => {
  const img = new Image();
  img.src = entry.src;
  preloadedScreens.set(key, img);
});

let isTransitioning = false;
let pendingScreen = null;

function transitionScreen(targetKey) {
  const spec = screenCatalog[targetKey];
  if (!spec || !preview || !currentImg) return;

  const activeKey = preview.dataset.screen || 'windows';
  if (targetKey === activeKey && !isTransitioning) return;

  if (isTransitioning) {
    pendingScreen = targetKey;
    return;
  }

  isTransitioning = true;
  preview.dataset.screen = targetKey;
  preview.setAttribute('aria-label', spec.ariaLabel);

  if (screenDesc) {
    screenDesc.classList.add('fading');
    setTimeout(() => {
      const strong = document.createElement('strong');
      strong.textContent = spec.title;
      screenDesc.replaceChildren(strong, document.createTextNode(' ' + spec.desc));
      screenDesc.classList.remove('fading');
    }, 120);
  }

  const finishImmediate = () => {
    currentImg.src = spec.src;
    currentImg.width = spec.width;
    currentImg.height = spec.height;
    currentImg.alt = spec.alt;
    isTransitioning = false;
    if (pendingScreen) {
      const next = pendingScreen;
      pendingScreen = null;
      transitionScreen(next);
    }
  };

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (prefersReducedMotion || !nextImg) {
    finishImmediate();
    return;
  }

  nextImg.src = spec.src;
  nextImg.width = spec.width;
  nextImg.height = spec.height;
  nextImg.alt = spec.alt;

  let settled = false;
  const finish = () => {
    if (settled) return;
    settled = true;

    currentImg.src = spec.src;
    currentImg.width = spec.width;
    currentImg.height = spec.height;
    currentImg.alt = spec.alt;
    nextImg.classList.remove('visible');
    isTransitioning = false;

    if (pendingScreen) {
      const next = pendingScreen;
      pendingScreen = null;
      transitionScreen(next);
    }
  };

  const onLoaded = () => {
    void nextImg.offsetWidth;
    nextImg.classList.add('visible');

    const onEnd = (event) => {
      if (event.target !== nextImg || event.propertyName !== 'opacity') return;
      nextImg.removeEventListener('transitionend', onEnd);
      finish();
    };

    nextImg.addEventListener('transitionend', onEnd);
    setTimeout(() => {
      nextImg.removeEventListener('transitionend', onEnd);
      finish();
    }, 380);
  };

  if (nextImg.complete && nextImg.naturalWidth > 0) {
    onLoaded();
  } else {
    nextImg.onload = onLoaded;
    nextImg.onerror = finish;
  }
}

screenButtons.forEach((button, index) => {
  button.addEventListener('click', () => {
    screenButtons.forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
    transitionScreen(button.dataset.screen);
  });

  button.addEventListener('keydown', (event) => {
    let targetIndex = -1;
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      targetIndex = (index + 1) % screenButtons.length;
    } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      targetIndex = (index - 1 + screenButtons.length) % screenButtons.length;
    }
    if (targetIndex >= 0) {
      event.preventDefault();
      screenButtons[targetIndex].focus();
      screenButtons[targetIndex].click();
    }
  });
});

// OS detection & GitHub Release asset binding
(function initDownloads() {
  const ua = navigator.userAgent || '';
  const isAndroid = /android/i.test(ua);

  const heroPrimary = document.getElementById('hero-primary-btn');
  const heroSecondary = document.getElementById('hero-secondary-btn');
  const heroActions = document.getElementById('hero-actions');
  const winDownload = document.getElementById('download-windows');
  const andDownload = document.getElementById('download-android');
  const versionEyebrow = document.getElementById('version-eyebrow');
  const releaseNote = document.getElementById('release-note');

  // On Android devices, promote Android APK button to primary visually & first in actions row
  if (isAndroid && heroPrimary && heroSecondary && heroActions) {
    heroPrimary.classList.remove('button-primary');
    heroPrimary.classList.add('button-secondary');
    heroSecondary.classList.remove('button-secondary');
    heroSecondary.classList.add('button-primary');
    heroActions.prepend(heroSecondary);
  }

  async function resolveLatestRelease() {
    try {
      const response = await fetch('https://api.github.com/repos/OmarAfifi-CSE/daphq/releases/latest');
      if (!response.ok) return;
      const data = await response.json();

      if (data.tag_name) {
        if (versionEyebrow) {
          versionEyebrow.textContent = `${data.tag_name.toUpperCase()} · WINDOWS & ANDROID · 5GHZ WI-FI`;
        }
        if (releaseNote) {
          releaseNote.textContent = `Latest release ${data.tag_name} · Hosted cleanly on GitHub Releases`;
        }
      }

      if (!Array.isArray(data.assets)) return;
      let apkUrl = '';
      let windowsUrl = '';

      data.assets.forEach((asset) => {
        if (typeof asset?.name !== 'string' || typeof asset?.browser_download_url !== 'string') return;
        const lower = asset.name.toLowerCase();
        if (lower.endsWith('.apk') && !apkUrl) {
          apkUrl = asset.browser_download_url;
        } else if ((lower.endsWith('.exe') || lower.endsWith('.zip') || lower.endsWith('.msix')) && !windowsUrl) {
          windowsUrl = asset.browser_download_url;
        }
      });

      if (windowsUrl) {
        if (heroPrimary) heroPrimary.href = windowsUrl;
        if (winDownload) winDownload.href = windowsUrl;
      }
      if (apkUrl) {
        if (heroSecondary) heroSecondary.href = apkUrl;
        if (andDownload) andDownload.href = apkUrl;
      }
    } catch (_) {
      // Keep fallback links to /releases/latest silently on offline/rate-limited requests.
    }
  }

  resolveLatestRelease();
})();

// Interactive constellation background + accessible motion control
(function initNetworkBackground() {
  if (typeof NetworkBackground === 'undefined') return;
  const bg = new NetworkBackground('network-canvas');
  const toggleBtn = document.getElementById('motion-toggle');
  if (!toggleBtn) return;

  const syncLabel = () => {
    toggleBtn.textContent = bg.userPaused ? 'Play background' : 'Pause background';
  };
  syncLabel();

  toggleBtn.addEventListener('click', () => {
    bg.setPaused(!bg.userPaused);
    syncLabel();
  });
})();

document.addEventListener('DOMContentLoaded', () => {
    // 1. Navbar Scroll Effect
    const navbar = document.querySelector('.navbar');
    
    window.addEventListener('scroll', () => {
        if (window.scrollY > 50) {
            navbar.classList.add('scrolled');
        } else {
            navbar.classList.remove('scrolled');
        }
    });

    // 2. Intersection Observer for Fade-Up Animations
    const observerOptions = {
        root: null,
        rootMargin: '0px',
        threshold: 0.15
    };

    const observer = new IntersectionObserver((entries, observer) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('visible');
                // Optional: Stop observing once animated
                observer.unobserve(entry.target);
            }
        });
    }, observerOptions);

    // Select all elements with the fade-up class
    const fadeElements = document.querySelectorAll('.fade-up');
    fadeElements.forEach(el => {
        observer.observe(el);
    });

    // 3. Dynamic OS Detection and GitHub Release Fetch
    const mainDownloadBtn = document.getElementById('main-download-btn');
    const winBtn = document.getElementById('download-windows');
    const andBtn = document.getElementById('download-android');
    const heroAndBtn = document.getElementById('hero-android-btn');
    const userAgent = navigator.userAgent || navigator.vendor || window.opera;
    let isAndroid = /android/i.test(userAgent);
    let isWindows = /windows/i.test(userAgent);

    // Initial OS Text Setup for main button
    if (mainDownloadBtn) {
        if (isAndroid) {
            mainDownloadBtn.innerHTML = '<i class="fab fa-android"></i> Download for Android';
        } else if (isWindows) {
            mainDownloadBtn.innerHTML = '<i class="fab fa-windows"></i> Download for Windows';
        }
    }

    // Fetch actual release links
    async function fetchLatestRelease() {
        try {
            const response = await fetch('https://api.github.com/repos/OmarAfifi-CSE/daphq/releases/latest');
            if (!response.ok) return;
            const data = await response.json();
            
            // Update version badge
            const versionBadge = document.getElementById('version-badge');
            if (versionBadge && data.tag_name) {
                versionBadge.innerText = `${data.tag_name} is Here!`;
            }
            
            let apkUrl = '';
            let windowsUrl = '';

            data.assets.forEach(asset => {
                if (asset.name.endsWith('.apk')) {
                    apkUrl = asset.browser_download_url;
                } else if (asset.name.endsWith('.zip') || asset.name.endsWith('.exe') || asset.name.endsWith('.msix')) {
                    windowsUrl = asset.browser_download_url;
                }
            });

            // Update bottom CTA buttons
            if (winBtn && windowsUrl) winBtn.href = windowsUrl;
            if (andBtn && apkUrl) andBtn.href = apkUrl;
            if (heroAndBtn && apkUrl) heroAndBtn.href = apkUrl;

            // Update main hero button based on OS
            if (mainDownloadBtn) {
                if (isAndroid && apkUrl) {
                    mainDownloadBtn.href = apkUrl;
                } else if (windowsUrl) {
                    // Default to Windows if not Android, or if explicitly Windows
                    mainDownloadBtn.href = windowsUrl;
                }
            }
        } catch (error) {
            console.error('Error fetching release:', error);
        }
    }

    fetchLatestRelease();
});

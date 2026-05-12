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

    // 3. Dynamic OS Detection for Primary Download Button
    const mainDownloadBtn = document.getElementById('main-download-btn');
    if (mainDownloadBtn) {
        const userAgent = navigator.userAgent || navigator.vendor || window.opera;
        
        if (/android/i.test(userAgent)) {
            mainDownloadBtn.innerHTML = '<span class="icon">📱</span> Download for Android';
            // Optionally update href if you have specific direct links
            // mainDownloadBtn.href = "android_link";
        } else if (/windows/i.test(userAgent)) {
            mainDownloadBtn.innerHTML = '<span class="icon">💻</span> Download for Windows';
            // mainDownloadBtn.href = "windows_link";
        }
    }
});

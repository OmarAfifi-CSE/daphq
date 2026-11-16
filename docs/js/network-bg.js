/**
 * Daphq - Interactive Constellation Background
 * Smooth proximity particle network matching the in-app Orbital Radar aesthetic.
 */
'use strict';

class NetworkParticle {
  constructor(width, height) {
    this.x = Math.random() * width;
    this.y = Math.random() * height;
    this.vx = (Math.random() - 0.5) * 0.55;
    this.vy = (Math.random() - 0.5) * 0.55;
    this.radius = Math.random() * 1.9 + 1;
  }

  update(width, height, mouse) {
    this.x += this.vx;
    this.y += this.vy;

    if (this.x < 0) {
      this.x = 0;
      this.vx *= -1;
    } else if (this.x > width) {
      this.x = width;
      this.vx *= -1;
    }

    if (this.y < 0) {
      this.y = 0;
      this.vy *= -1;
    } else if (this.y > height) {
      this.y = height;
      this.vy *= -1;
    }

    if (mouse.x !== null && mouse.y !== null) {
      const dx = mouse.x - this.x;
      const dy = mouse.y - this.y;
      const distance = Math.hypot(dx, dy);
      if (distance > 0 && distance < mouse.radius) {
        const force = (mouse.radius - distance) / mouse.radius;
        this.x -= dx * force * 0.02;
        this.y -= dy * force * 0.02;
      }
    }
  }

  draw(ctx) {
    ctx.fillStyle = 'rgba(100, 181, 246, 0.85)';
    ctx.beginPath();
    ctx.arc(this.x, this.y, this.radius, 0, Math.PI * 2);
    ctx.fill();
  }
}

class NetworkBackground {
  constructor(canvasId) {
    this.canvas = document.getElementById(canvasId);
    if (!this.canvas) return;
    this.ctx = this.canvas.getContext('2d');
    if (!this.ctx) return;

    this.particles = [];
    this.mouse = { x: null, y: null, radius: 150 };
    this.connectionDistance = 150;
    this.rafId = null;
    this.reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    this.userPaused = this.reducedMotionQuery.matches;
    this.overrideReducedMotion = false;

    this.onResize = () => this.resize();
    this.onMouseMove = (event) => {
      this.mouse.x = event.clientX;
      this.mouse.y = event.clientY;
    };
    this.onMouseLeave = () => {
      this.mouse.x = null;
      this.mouse.y = null;
    };
    this.onVisibilityChange = () => this.syncPlayback();
    this.onReducedMotionChange = () => this.syncPlayback();

    window.addEventListener('resize', this.onResize);
    window.addEventListener('mousemove', this.onMouseMove, { passive: true });
    window.addEventListener('mouseleave', this.onMouseLeave);
    document.addEventListener('visibilitychange', this.onVisibilityChange);
    this.reducedMotionQuery.addEventListener('change', this.onReducedMotionChange);

    this.init();
    this.syncPlayback();
  }

  init() {
    this.resize();
    const count = window.innerWidth < 700 ? 48 : 80;
    this.particles = [];
    for (let i = 0; i < count; i++) {
      this.particles.push(new NetworkParticle(this.canvas.width, this.canvas.height));
    }
    this.draw(false);
  }

  resize() {
    this.canvas.width = window.innerWidth;
    this.canvas.height = window.innerHeight;
  }

  shouldAnimate() {
    if (this.userPaused || document.hidden) return false;
    return this.overrideReducedMotion || !this.reducedMotionQuery.matches;
  }

  setPaused(paused) {
    this.userPaused = paused;
    this.overrideReducedMotion = !paused;
    this.syncPlayback();
  }

  isPaused() {
    return !this.shouldAnimate();
  }

  syncPlayback() {
    if (this.shouldAnimate()) {
      if (this.rafId === null) {
        const step = () => {
          if (!this.shouldAnimate()) {
            this.rafId = null;
            return;
          }
          this.draw(true);
          this.rafId = requestAnimationFrame(step);
        };
        this.rafId = requestAnimationFrame(step);
      }
    } else if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  draw(advance) {
    const { width, height } = this.canvas;
    this.ctx.clearRect(0, 0, width, height);

    for (let i = 0; i < this.particles.length; i++) {
      const particle = this.particles[i];
      if (advance) {
        particle.update(width, height, this.mouse);
      }
      particle.draw(this.ctx);

      for (let j = i + 1; j < this.particles.length; j++) {
        const other = this.particles[j];
        const dx = particle.x - other.x;
        const dy = particle.y - other.y;
        const distance = Math.hypot(dx, dy);

        if (distance < this.connectionDistance) {
          const opacity = 1 - distance / this.connectionDistance;
          this.ctx.strokeStyle = `rgba(68, 138, 255, ${(opacity * 0.24).toFixed(3)})`;
          this.ctx.lineWidth = 1;
          this.ctx.beginPath();
          this.ctx.moveTo(particle.x, particle.y);
          this.ctx.lineTo(other.x, other.y);
          this.ctx.stroke();
        }
      }
    }
  }
}

window.NetworkBackground = NetworkBackground;

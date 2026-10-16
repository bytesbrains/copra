// Tailwind Play CDN theme config. External (not inline) so the CSP needs no 'unsafe-inline' for scripts.
// Must load after https://cdn.tailwindcss.com.
tailwind.config = {
  theme: {
    extend: {
      fontFamily: {
        sans: ['"Plus Jakarta Sans"', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'monospace'],
      },
      colors: {
        brand: {
          50: '#f0fdf4',
          500: '#22c55e',
          600: '#16a34a',
          900: '#14532d',
          dark: '#0a0f0d',
          card: '#111915',
          border: '#1f2e26'
        }
      }
    }
  }
};

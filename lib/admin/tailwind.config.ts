import type { Config } from 'tailwindcss';
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink: { DEFAULT: '#10222F', 700: '#1B3446', 500: '#4B6172', 300: '#8FA1AF' },
        sea: { DEFAULT: '#0E7C86', 600: '#0B646C', 100: '#D6ECEE', 50: '#EBF6F7' },
        paper: '#F5F6F3',
        line: '#E1E5E0',
        amber: { DEFAULT: '#B7791F', 100: '#FBEFD5' },
        coral: { DEFAULT: '#C2402B', 100: '#F9E1DC' },
        moss: { DEFAULT: '#2F7D4F', 100: '#DDF0E4' },
      },
      fontFamily: { sans: ['"Schibsted Grotesk"', 'ui-sans-serif', 'system-ui', 'Segoe UI', 'sans-serif'] },
    },
  },
  plugins: [],
};
export default config;

import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: "#1C1C1A",
        paper: "#F7F6F2",
        line: "#E5E3DD",
        brass: "#344E41",
        brassLight: "#4A6857",
        brassDeep: "#243830",
        moss: "#344E41",
        rose: "#9C4F45",
        ivory: "#F7F6F2",
        charcoal: "#1C1C1A",
        sage: "#344E41",
        sageSoft: "#E7EDE8",
        borderSoft: "#E5E3DD",
      },
      fontFamily: {
        arabic: ["var(--font-arabic)", "Tahoma", "Arial", "sans-serif"],
        display: ["var(--font-arabic)", "Tahoma", "Arial", "sans-serif"],
      },
      borderRadius: {
        card: "0.625rem",
      },
      keyframes: {
        "auth-rise": { "0%": { opacity: "0", transform: "translateY(10px)" }, "100%": { opacity: "1", transform: "translateY(0)" } },
        "auth-shake": { "0%,100%": { transform: "translateX(0)" }, "25%": { transform: "translateX(-4px)" }, "75%": { transform: "translateX(4px)" } },
      },
      animation: {
        "auth-rise": "auth-rise 0.45s cubic-bezier(0.22,1,0.36,1) both",
        "auth-shake": "auth-shake 0.28s ease-in-out",
      },
    },
  },
  plugins: [],
};
export default config;

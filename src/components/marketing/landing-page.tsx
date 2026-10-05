import { Navbar } from "./navbar";
import { Hero } from "./hero";
import { Stats } from "./stats";
import { Features } from "./features";
import { HowItWorks } from "./how-it-works";
import { FinalCta } from "./final-cta";
import { MarketingFooter } from "./footer";
import { SignalSurface } from "./signal-surface";
import { ScrollProgress } from "./scroll-progress";
import { SmoothScroll } from "./smooth-scroll";
import { MotionProvider } from "../motion-provider";

export function LandingPage() {
  return (
    <SmoothScroll>
      <MotionProvider>
      <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
        <ScrollProgress />
        <Navbar />
        <Hero />
        <Stats />
        <SignalSurface />
        <Features />
        <HowItWorks />
        <FinalCta />
        <MarketingFooter />
      </div>
      </MotionProvider>
    </SmoothScroll>
  );
}

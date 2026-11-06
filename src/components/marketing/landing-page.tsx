import { Navbar } from "./navbar";
import { Hero } from "./hero";
import { Stats } from "./stats";
import { Features } from "./features";
import { Roles } from "./roles";
import { HowItWorks } from "./how-it-works";
import { FinalCta } from "./final-cta";
import { MarketingFooter } from "./footer";
import { SignalSurface } from "./signal-surface";
import { ScrollProgress } from "./scroll-progress";
import { SmoothScroll } from "./smooth-scroll";
import { MotionProvider } from "../motion-provider";

export function LandingPage({ signedIn = false, trialDays = null }: { signedIn?: boolean; trialDays?: number | null }) {
  return (
    <SmoothScroll>
      <MotionProvider>
      <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
        <ScrollProgress />
        <Navbar signedIn={signedIn} trialDays={trialDays} />
        <Hero signedIn={signedIn} trialDays={trialDays} />
        <Stats />
        <SignalSurface />
        <Features />
        <Roles />
        <HowItWorks />
        <FinalCta signedIn={signedIn} trialDays={trialDays} />
        <MarketingFooter signedIn={signedIn} />
      </div>
      </MotionProvider>
    </SmoothScroll>
  );
}

import Navbar from "@/components/Navbar";
import Hero from "@/components/Hero";
import StatsBar from "@/components/StatsBar";
import HowItWorks from "@/components/HowItWorks";
import Features from "@/components/Features";
import Audience from "@/components/Audience";
import CallToAction from "@/components/CallToAction";
import Footer from "@/components/Footer";

export default function Home() {
  return (
    <>
      <Navbar />
      <Hero />
      <StatsBar />
      <HowItWorks />
      <Features />
      <Audience />
      <CallToAction />
      <Footer />
    </>
  );
}

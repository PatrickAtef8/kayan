import { ForgotPasswordForm } from "./forgot-form";

// The login screen passes ?email= so the address does not have to be typed twice.
export default async function ForgotPasswordPage({ searchParams }: { searchParams: Promise<{ email?: string | string[] }> }) {
  const { email } = await searchParams;
  return <ForgotPasswordForm initialEmail={typeof email === "string" ? email.slice(0, 254) : ""} />;
}

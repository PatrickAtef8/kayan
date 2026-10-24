import { LoginForm } from "./login-form";

// /login?confirmed=1 is where the email-confirmation link lands when it cannot start a session itself.
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ confirmed?: string }> }) {
  const { confirmed } = await searchParams;
  return <LoginForm confirmed={confirmed === "1"} />;
}

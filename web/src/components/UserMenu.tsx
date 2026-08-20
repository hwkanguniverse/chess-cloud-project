/**
 * Who is signed in, and a way out.
 *
 * Uses useAuthenticator rather than a local useState around getCurrentUser:
 * Amplify's context updates when the session changes anywhere in the app, so
 * signing in on the submit screen updates this header without a reload.
 */
import { useAuthenticator } from "@aws-amplify/ui-react";

export default function UserMenu() {
  const { user, signOut, authStatus } = useAuthenticator((context) => [
    context.user,
    context.authStatus,
  ]);

  if (authStatus !== "authenticated" || !user) {
    // No "sign in" button here on purpose: the submit screen prompts for it at
    // the point it is actually needed, which is the only place it is.
    return <span className="user-menu muted">not signed in</span>;
  }

  return (
    <span className="user-menu">
      <span className="muted">{user.signInDetails?.loginId ?? user.username}</span>
      <button type="button" className="link-button" onClick={signOut}>
        sign out
      </button>
    </span>
  );
}

/**
 * Cognito configuration for Amplify.
 *
 * This is deliberately the *only* place auth is configured. Amplify keeps the
 * session in a module-level singleton, so calling configure() twice from
 * different files is a real source of "signed in on one page, signed out on
 * the next" bugs.
 *
 * Note what is absent: a client secret. The app client is public
 * (generate_secret = false in terraform/auth), because a secret shipped to a
 * browser is not a secret. The pool id and client id below are public
 * identifiers - they name which pool to talk to, they do not authorise
 * anything. Anyone can read them out of the bundle, and that is fine.
 */
import { Amplify } from "aws-amplify";

const userPoolId = import.meta.env.VITE_USER_POOL_ID;
const userPoolClientId = import.meta.env.VITE_USER_POOL_CLIENT_ID;

if (!userPoolId || !userPoolClientId) {
  // Fail loudly at startup rather than at the first sign-in attempt. A missing
  // .env otherwise surfaces as an opaque Amplify error inside the login form.
  throw new Error(
    "Missing VITE_USER_POOL_ID or VITE_USER_POOL_CLIENT_ID - copy .env.example to .env",
  );
}

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId,
      userPoolClientId,

      // No authFlowType here: Amplify v6 defaults to SRP, and the pool only
      // allows ALLOW_USER_SRP_AUTH and ALLOW_REFRESH_TOKEN_AUTH anyway - so
      // the password is never sent to Cognito, only a proof of knowing it.
      // (The option lives on signIn() in v6, not on the config; setting it
      // here is a type error rather than a silent no-op, which is the good
      // outcome.)

      // Email is the username: the pool sets username_attributes = ["email"],
      // so there is no separate username to collect. Telling the UI this is
      // what makes the sign-up form ask for an email rather than both.
      loginWith: { email: true },

      signUpVerificationMethod: "code",
    },
  },
});

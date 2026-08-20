/**
 * Entry point. The import order here is load-bearing: ./amplify must run
 * before any component that calls an auth function, so it is imported first
 * and for its side effect rather than for a value.
 */
import "./amplify";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { Authenticator } from "@aws-amplify/ui-react";

import "@aws-amplify/ui-react/styles.css";
import "./index.css";
import App from "./App";

// Authenticator.Provider, not <Authenticator> - the provider supplies the auth
// context that useAuthenticator reads, without rendering a login form. The
// form itself is mounted only on the submit screen, so the header can know who
// is signed in while the public screens stay ungated.
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Authenticator.Provider>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </Authenticator.Provider>
  </StrictMode>,
);

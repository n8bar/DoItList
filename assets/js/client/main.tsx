// Entry point for the React client served at /app. Placeholder shell — the
// real tree lands in a later task. The LiveView app (js/app.js) is untouched
// and keeps its own bundle.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

function App() {
  return <h1>Do It List client</h1>;
}

const container = document.getElementById("app");

if (container) {
  createRoot(container).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

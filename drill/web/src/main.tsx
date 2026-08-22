import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./theme.css";
// Monaco is deliberately NOT imported here. It is most of the bundle, and pulling
// it in at the entry point means the terminal - the thing you actually need first -
// waits on a few megabytes of editor. App lazy-loads the editor panel instead, so
// Monaco arrives in its own chunk after the console has painted.
import { App } from "./App.tsx";

const root = document.getElementById("root");
if (!root) throw new Error("#root is missing from index.html");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

import React from "react";
import { createRoot } from "react-dom/client";
import "../app/globals.css";
import Dashboard from "../ui/Dashboard";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><Dashboard /></React.StrictMode>,
);

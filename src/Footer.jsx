import React from "react";

// Werte werden beim Build von der Pipeline gesetzt (siehe deploy.yml / Dockerfile),
// damit auf der Website sichtbar ist, welcher Commit wo deployt wurde.
const buildSha = import.meta.env.VITE_BUILD_SHA || "local";
const deployTarget = import.meta.env.VITE_DEPLOY_TARGET || "dev";

export default function Footer() {
  return (
    <footer>
      <p>
        This site is created for demonstrative purposes only and does not offer
        any real products or services.
      </p>
      <p data-testid="build-info">
        RefCard02 – Johan Stefanes · Build {buildSha} · Target {deployTarget}
      </p>
      <p>&copy; BBW 2026/2027</p>
    </footer>
  );
}

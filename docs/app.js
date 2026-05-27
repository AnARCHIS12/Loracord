const repo = (() => {
  const match = location.hostname.match(/^([^.]+)\.github\.io$/);
  const project = location.pathname.split("/").filter(Boolean)[0];
  if (match && project) return `${match[1]}/${project}`;
  return document.documentElement.dataset.repo || "";
})();

const repoLinks = document.querySelectorAll("[data-repo-link]");
const releaseStatus = document.querySelector("#release-status");
const releaseTitle = document.querySelector("#release-title");
const releaseMeta = document.querySelector("#release-meta");
const releaseCopy = document.querySelector("#release-copy");
const releaseLink = document.querySelector("#release-link");
const apkLink = document.querySelector("#apk-link");
const heroDownload = document.querySelector("#hero-download");

function setRepoLinks() {
  if (!repo) return;
  for (const link of repoLinks) {
    link.href = `https://github.com/${repo}`;
  }
}

function formatSize(bytes) {
  if (!Number.isFinite(bytes)) return "";
  const mb = bytes / 1024 / 1024;
  return `${mb.toFixed(1)} MB`;
}

async function loadLatestRelease() {
  if (!repo) {
    releaseStatus.textContent =
      "Publish the site on GitHub Pages to enable the download button.";
    return;
  }

  try {
    const response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) throw new Error(`release ${response.status}`);
    const release = await response.json();
    const apk = release.assets.find((asset) => asset.name.toLowerCase().endsWith(".apk"));

    releaseTitle.textContent = release.name || release.tag_name;
    releaseMeta.textContent = apk
      ? `${release.tag_name} - ${formatSize(apk.size)}`
      : `${release.tag_name} - no APK attached`;
    releaseCopy.textContent = apk
      ? "Latest Android build ready to install on a phone connected to a Meshtastic node."
      : "The release exists, but no APK file is attached yet.";

    releaseLink.hidden = false;
    releaseLink.href = release.html_url;

    if (apk) {
      apkLink.textContent = `Download ${apk.name}`;
      apkLink.href = apk.browser_download_url;
      apkLink.classList.remove("disabled");
      apkLink.removeAttribute("aria-disabled");
      heroDownload.href = apk.browser_download_url;
      releaseStatus.textContent = `Latest release available: ${release.tag_name}`;
    } else {
      releaseStatus.textContent = "Latest release found, but the APK is missing.";
    }
  } catch (error) {
    releaseStatus.textContent = "No APK release has been published yet.";
    releaseMeta.textContent = "Push a v* tag to generate a release.";
  }
}

setRepoLinks();
loadLatestRelease();

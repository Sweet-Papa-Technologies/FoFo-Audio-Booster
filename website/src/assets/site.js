const slider = document.querySelector("#preview-boost");
const output = document.querySelector("#boost-value");
if (slider && output) {
  const update = () => {
    const value = Number(slider.value);
    output.replaceChildren(
      document.createTextNode(`+${value} `),
      Object.assign(document.createElement("small"), { textContent: "dB" }),
    );
    slider.setAttribute(
      "aria-valuetext",
      `${value} decibels of boost in the preview`,
    );
    slider.style.background = `linear-gradient(to right,#f8985a 0%,#f8985a ${(value / 12) * 100}%,#687365 ${(value / 12) * 100}%,#687365 100%)`;
    document
      .querySelector(".hero-stage")
      .style.setProperty("--preview-gain", value);
  };
  slider.addEventListener("input", update);
  update();
}
const preview = document.querySelector(".visualizer-demo");
const descriptions = {
  ember: "A warm spectrum glow.",
  halo: "A circle of sound.",
  tide: "Every sound leaves a trace.",
  grid: "A little retro rhythm.",
  drift: "Room to wander.",
};
for (const button of document.querySelectorAll(
  ".preset-controls [data-preset]",
)) {
  button.addEventListener("click", () => {
    preview.dataset.preset = button.dataset.preset;
    for (const other of document.querySelectorAll(
      ".preset-controls [data-preset]",
    ))
      other.setAttribute("aria-pressed", String(other === button));
    document.querySelector("#preset-title").textContent = button.textContent;
    document.querySelector("#preset-description").textContent =
      descriptions[button.dataset.preset];
  });
}
const motion = document.querySelector("#motion-toggle");
if (motion && preview) {
  const preference = matchMedia("(prefers-reduced-motion: reduce)");
  let paused = preference.matches;
  const update = () => {
    preview.dataset.motion = paused ? "paused" : "playing";
    motion.setAttribute("aria-pressed", String(paused));
    motion.textContent = paused ? "Motion paused ▶" : "Pause motion Ⅱ";
    motion.disabled = preference.matches;
    motion.title = preference.matches
      ? "Motion is disabled by your system preference."
      : "";
  };
  motion.addEventListener("click", () => {
    paused = !paused;
    update();
  });
  preference.addEventListener("change", () => {
    paused = preference.matches;
    update();
  });
  update();
}

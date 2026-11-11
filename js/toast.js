export function toast(message, type = "success") {
  const root = document.getElementById("toasts");
  if (!root) return;
  const item = document.createElement("div");
  item.className = `pointer-events-none mb-2 rounded-2xl px-4 py-3 text-sm font-medium shadow-lg transition duration-300 ${
    type === "error" ? "bg-rose-600 text-white" : "bg-emerald-500 text-emerald-950"
  }`;
  item.textContent = message;
  item.style.opacity = "0";
  item.style.transform = "translateY(-8px)";
  root.appendChild(item);
  requestAnimationFrame(() => {
    item.style.opacity = "1";
    item.style.transform = "translateY(0)";
  });
  setTimeout(() => {
    item.style.opacity = "0";
    setTimeout(() => item.remove(), 300);
  }, 3400);
}

require("dotenv").config();
const { Telegraf } = require("telegraf");
const express = require("express");

const bot = new Telegraf(process.env.BOT_TOKEN);
const app = express();

const ALLOWED_USER_ID = 5978153872;
let queue = [];

/* ================= PARSE TELEGRAM SIGNAL ================= */

function parseSignal(text) {
  // ---- SYMBOL: không phân biệt hoa/thường ----
  // Nếu không match được symbol -> mặc định XAUUSD
  const symbolMatch = text.match(/^(xauusd[a-z]?|[a-z]{6})/i);

  // chuẩn hoá symbol về IN HOA (EA xử lý suffix sau)
  const symbol = (symbolMatch ? symbolMatch[1] : "XAUUSD").toUpperCase();

  // ---- TYPE ----
  const upperText = text.toUpperCase();
  const type = upperText.includes("BUY")
    ? "BUY_LIMIT"
    : upperText.includes("SELL")
    ? "SELL_LIMIT"
    : null;
  if (!type) return null;

  // ---- ENTRIES ----
  const entryMatch = text.match(/🕛:\s*([\d.\s-]+)/);
  if (!entryMatch) return null;
  const entries = entryMatch[1]
    .split("-")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !isNaN(v));

  if (!entries.length) return null;

  // ---- SL ----
  const slMatch = text.match(/🛑:\s*([\d.]+)/);
  if (!slMatch) return null;
  const sl = parseFloat(slMatch[1]);
  if (isNaN(sl)) return null;

  // ---- TP ----
  const tpMatch = text.match(/🎯:\s*([\d.\s-]+)/);
  if (!tpMatch) return null;
  const tps = tpMatch[1]
    .split("-")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !isNaN(v));

  // ---- LOT / RISK (NEW FORMAT) ----
  // Only treat as: @price, totalRisk[, lot1, lot2, ...]
  // If lots are provided after totalRisk and enough for all entries -> use them
  // Else -> compute lots from totalRisk
  const lotMatch = text.match(/@[\d.]+,\s*([\d.,\s]+)/);
  if (!lotMatch) return null;

  const nums = lotMatch[1]
    .split(",")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !isNaN(v));

  const n = entries.length;
  if (nums.length < 1) return null;

  const totalRisk = nums[0]; // ✅ NEW FORMAT: totalRisk is first
  const lotsCandidate = nums.slice(1);

  let lots = [];

  // If user provides enough lots after totalRisk -> use them
  if (lotsCandidate.length >= n) {
    lots = lotsCandidate.slice(0, n).map((x) => Number(x.toFixed(3)));
  } else {
    // Otherwise compute lots from totalRisk
    let risks = [];

    // phân bổ risk:
    // 1 entry: 100%
    // 2 entries: 50/50
    // >=3 entries: 40/40/20 (giữ đúng logic cũ của bạn)
    if (n === 1) {
      risks = [totalRisk];
    } else if (n === 2) {
      risks = [totalRisk / 2, totalRisk / 2];
    } else {
      const riskFirstTwo = totalRisk * 0.8;
      const riskEachFirst = riskFirstTwo / 2;
      const riskLast = totalRisk * 0.2;

      risks = entries.map((_, i) => {
        if (i === 0 || i === 1) return riskEachFirst;
        if (i === n - 1) return riskLast;
        return 0; // nếu n > 3, entry ở giữa để 0 như logic cũ
      });
    }

    lots = entries.map((entry, i) => {
      const distance = type === "SELL_LIMIT" ? sl - entry : entry - sl;
      if (distance <= 0) return 0;

      // XAUUSD: 1 lot = 100 USD / 1 giá
      const lot = risks[i] / (distance * 100);
      return Math.max(0, Number(lot.toFixed(3)));
    });
  }

  // đảm bảo lots đúng độ dài n
  lots = Array.from({ length: n }, (_, i) => (typeof lots[i] === "number" ? lots[i] : 0));

  let orders = entries.map((entry, i) => ({
    entry,
    tp: typeof tps[i] === "number" ? tps[i] : null,
    lot: lots[i],
  }));

  // ✅ MERGE nếu 2 entry đầu giống nhau
  if (orders.length >= 2 && orders[0].entry === orders[1].entry) {
    const mergedOrder = {
      entry: orders[0].entry,
      lot: Number((orders[0].lot + orders[1].lot).toFixed(3)),
      tp: orders[1].tp ?? orders[0].tp, // ưu tiên TP lệnh 2
    };

    // giữ lại các lệnh còn lại (từ index 2 trở đi)
    orders = [mergedOrder, ...orders.slice(2)];
  }

  return {
    symbol,
    type,
    sl,
    orders,
    createdAt: Date.now(),
  };
}

/* ================= TELEGRAM BOT ================= */

bot.on("text", (ctx) => {
  if (ctx.from.id !== ALLOWED_USER_ID || ctx.chat.id !== ALLOWED_USER_ID) return;

  const signal = parseSignal(ctx.message.text);
  if (!signal) return;

  // ✅ dùng thật thì bật dòng này để MT5 pull được
  queue.push(signal);
  ctx.reply(JSON.stringify(signal, null, 2));

  // console.log("Queued signal:\n", JSON.stringify(signal, null, 2));
});

bot.launch();

/* ================= API FOR MT5 ================= */

app.get("/pull", (req, res) => {
  if (queue.length === 0) return res.send("");
  res.json(queue.shift());
});

app.get("/ping", (req, res) => {
  return res.send("pong");
});

app.listen(3001, () => {
  console.log("Signal server running at http://127.0.0.1:3001");
});

require("dotenv").config();

const { Telegraf } = require("telegraf");
const { TelegramClient } = require("telegram");
const { StringSession } = require("telegram/sessions");
const express = require("express");
const net = require("net");
const fs = require("fs");
const path = require("path");

/*
 * File tải xuống được để đuôi .js1.
 * Khi chạy thật, module Forex News có thể là forexNews.js1 hoặc forexNews.js
 */
const forexNewsModulePath = fs.existsSync(path.join(__dirname, "forexNews.js1"))
  ? "./forexNews.js1"
  : "./forexNews.js";

const { createForexNews } = require(forexNewsModulePath);

/* ============================================================
   CONFIG
============================================================ */

function mustEnv(name) {
  const value = process.env[name];

  if (!value) {
    throw new Error(`Missing env: ${name}`);
  }

  return value;
}

const CONFIG = {
  apiId: Number(mustEnv("A_ID")),
  apiHash: mustEnv("A_HASH"),
  session: mustEnv("A_SS"),
  botToken: mustEnv("BOT_TOKEN"),

  httpPort: Number(process.env.HTTP_PORT || 3001),
  tcpPort: Number(process.env.TCP_PORT || 3002),
  tcpHost: process.env.TCP_HOST || "0.0.0.0",

  socketToken: process.env.SOCKET_TOKEN || "CHANGE_ME_STRONG_TOKEN",

  // File cấu hình nhóm EA + R mỗi nhóm + TP R multiple
  groupsFile: process.env.GROUPS_FILE || path.join(__dirname, "groups.json"),
};

/* ============================================================
   TELEGRAM CONFIG
============================================================ */

// Chỉ tài khoản Telegram của bạn được phép gửi lệnh trade
const ALLOWED_USER_ID = 5978153872;

// Channel nhận tín hiệu M5/M15
const CHANNEL_A = -1003256916567;

// Nếu M15 cùng hướng M5 thì forward sang đây
const CHANNEL_B = -1003479291587;

// Số message nhìn ngược lại khi M15 xuất hiện
const PREVIOUS_MESSAGE_LOOKBACK = 2;

/* ============================================================
   GROUP CONFIG (groups.json)

   {
     "tpRMultiple": 3,
     "defaultGroup": null,
     "groups":   { "A": { "riskUsd": 25,  "maxRiskUsd": 100 },
                   "B": { "riskUsd": 250, "maxRiskUsd": 1000 } },
     "accounts": { "12345678": "A",
                   "87654321@ICMarkets-Demo": "B" }
   }

   - Tên nhóm không phân biệt hoa/thường, lưu dạng HOA.
   - accounts: key là "login@server" (ưu tiên) hoặc chỉ "login".
   - defaultGroup: nhóm cho tài khoản chưa khai báo. null = từ chối kết nối.
   - maxRiskUsd: chặn trên khi đổi R bằng /r hoặc ghi đè trong tín hiệu.
   - Lệnh /r và /tpr ghi đè lại file này (format lại JSON).
============================================================ */

const TP_R_MULTIPLE_DEFAULT = 3;
const TP_R_MULTIPLE_MAX = 20;
const GROUP_NAME_RE = /^[A-Z0-9_]+$/;

const SAVE_WARN =
  "\n⚠️ Không ghi được groups.json, giá trị chỉ có hiệu lực tới khi restart.";

let groupConfig = null;

function sanitizeTpR(value, fallback) {
  const n = Number(value);

  return Number.isFinite(n) && n > 0 && n <= TP_R_MULTIPLE_MAX ? n : fallback;
}

function readGroupConfigFile() {
  const raw = JSON.parse(fs.readFileSync(CONFIG.groupsFile, "utf8"));

  const groups = {};

  for (const [rawName, g] of Object.entries(raw.groups || {})) {
    const name = String(rawName).toUpperCase();

    if (!GROUP_NAME_RE.test(name)) {
      throw new Error(`Tên nhóm không hợp lệ: "${rawName}" (chỉ A-Z, 0-9, _)`);
    }

    const maxRiskUsd = Number(g?.maxRiskUsd);
    const riskUsd = Number(g?.riskUsd);

    if (!(maxRiskUsd > 0)) {
      throw new Error(`Nhóm ${name}: maxRiskUsd phải > 0`);
    }

    if (!(riskUsd >= 0 && riskUsd <= maxRiskUsd)) {
      throw new Error(`Nhóm ${name}: riskUsd phải nằm trong 0..${maxRiskUsd}`);
    }

    groups[name] = { riskUsd, maxRiskUsd };
  }

  if (!Object.keys(groups).length) {
    throw new Error("groups.json chưa khai báo nhóm nào");
  }

  const accounts = {};

  for (const [account, rawGroup] of Object.entries(raw.accounts || {})) {
    const group = String(rawGroup).toUpperCase();

    if (!groups[group]) {
      throw new Error(`Account ${account} trỏ tới nhóm không tồn tại: ${rawGroup}`);
    }

    accounts[String(account).trim()] = group;
  }

  let defaultGroup = null;

  if (raw.defaultGroup) {
    defaultGroup = String(raw.defaultGroup).toUpperCase();

    if (!groups[defaultGroup]) {
      throw new Error(`defaultGroup không tồn tại: ${raw.defaultGroup}`);
    }
  }

  return {
    tpRMultiple: sanitizeTpR(
      raw.tpRMultiple ?? process.env.TP_R_MULTIPLE,
      TP_R_MULTIPLE_DEFAULT
    ),
    defaultGroup,
    groups,
    accounts,
  };
}

function saveGroupConfig() {
  const data = {
    tpRMultiple: groupConfig.tpRMultiple,
    defaultGroup: groupConfig.defaultGroup,
    groups: groupConfig.groups,
    accounts: groupConfig.accounts,
  };

  // Ghi ra file tạm rồi rename để không làm hỏng file nếu crash giữa chừng
  const tmp = `${CONFIG.groupsFile}.tmp`;

  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, CONFIG.groupsFile);
}

function trySaveGroupConfig() {
  try {
    saveGroupConfig();
    return true;
  } catch (error) {
    console.error("[GROUPS] Save error:", error?.message || error);
    return false;
  }
}

function resolveGroup(login, server) {
  if (!groupConfig) {
    return null;
  }

  if (login) {
    const byServer = groupConfig.accounts[`${login}@${server}`];

    if (byServer) {
      return byServer;
    }

    const byLogin = groupConfig.accounts[String(login)];

    if (byLogin) {
      return byLogin;
    }
  }

  return groupConfig.defaultGroup ?? null;
}

/*
 * Đọc lại groups.json lúc đang chạy (sau khi thêm tài khoản mới).
 * Lỗi file => throw, cấu hình cũ giữ nguyên.
 * EA đang kết nối được gán lại nhóm; EA không còn nhóm thì bị ngắt.
 */
function reloadGroupConfig() {
  const next = readGroupConfigFile();

  groupConfig = next;

  let kicked = 0;

  for (const client of clients) {
    if (!client.authenticated) {
      continue;
    }

    const group = resolveGroup(client.login, client.server);

    if (!group) {
      client.socket.destroy();
      kicked += 1;
      continue;
    }

    client.group = group;
  }

  return kicked;
}

function parseGroupArg(raw) {
  if (!raw) {
    return { group: null };
  }

  const group = raw.toUpperCase();

  if (!groupConfig.groups[group]) {
    return {
      error: `Nhóm không tồn tại: ${group}. Nhóm hiện có: ${Object.keys(
        groupConfig.groups
      ).join(", ")}`,
    };
  }

  return { group };
}

/* ============================================================
   CLIENTS / SERVERS
============================================================ */

const bot = new Telegraf(CONFIG.botToken);

const userClient = new TelegramClient(
  new StringSession(CONFIG.session),
  CONFIG.apiId,
  CONFIG.apiHash,
  { connectionRetries: 5 }
);

const app = express();

const clients = new Set();

let httpServer = null;
let shuttingDown = false;

/* ============================================================
   TELEGRAM ERROR HANDLER
============================================================ */

bot.catch((err, ctx) => {
  console.error(
    "Telegraf error:",
    err?.message || err,
    "| update:",
    ctx?.update?.update_id
  );
});

/* ============================================================
   FOREX FACTORY NEWS
   Phải khởi tạo trước bot.on("text") để /today, /news, /next
   không bị handler trade tổng quát nuốt mất.
============================================================ */

const forexNews = createForexNews(bot, {
  allowedUserId: ALLOWED_USER_ID,

  // Nếu để trống FOREX_NEWS_CHAT_ID thì phần gửi tự động sẽ bỏ qua.
  chatId: process.env.FOREX_NEWS_CHAT_ID
    ? Number(process.env.FOREX_NEWS_CHAT_ID)
    : null,

  timezone: process.env.FOREX_NEWS_TIMEZONE || "Asia/Ho_Chi_Minh",
  reportHour: Number(process.env.FOREX_NEWS_REPORT_HOUR || 7),
  reportMinute: Number(process.env.FOREX_NEWS_REPORT_MINUTE || 0),
  remindBeforeMinutes: Number(process.env.FOREX_NEWS_REMIND_MINUTES || 30),
});

/* ============================================================
   FILTER SIGNAL
   CHANNEL_A: M5 -> M15
============================================================ */

function parseFilterSignal(text = "") {
  const tf = text.match(/\b(5m|15m)\b/i)?.[1]?.toLowerCase() ?? null;
  const side = text.match(/\b(BUY|SELL)\b/i)?.[1]?.toUpperCase() ?? null;

  return { tf, side };
}

function isFromChannel(msg, channelId) {
  return msg?.chat?.id === channelId;
}

function getTelegramText(msg) {
  if (typeof msg?.text === "string") {
    return msg.text;
  }

  if (typeof msg?.caption === "string") {
    return msg.caption;
  }

  return "";
}

async function getPrevious5mSignal(
  channelId,
  currentMessageId,
  lookback = PREVIOUS_MESSAGE_LOOKBACK
) {
  const list = await userClient.getMessages(channelId, {
    limit: lookback,
    offsetId: currentMessageId,
  });

  for (const message of list || []) {
    const text = typeof message?.message === "string" ? message.message : "";

    if (!text) {
      continue;
    }

    const parsed = parseFilterSignal(text);

    if (parsed.tf === "5m" && parsed.side) {
      return {
        tf: parsed.tf,
        side: parsed.side,
        text,
        messageId: message.id,
        date: message.date,
      };
    }
  }

  return null;
}

/* ============================================================
   CHANNEL POST HANDLER
============================================================ */

bot.on("channel_post", async (ctx) => {
  const msg = ctx.channelPost;

  if (!msg || !isFromChannel(msg, CHANNEL_A)) {
    return;
  }

  const text = getTelegramText(msg);

  if (!text) {
    return;
  }

  const current = parseFilterSignal(text);

  // Chỉ quan tâm M15 BUY/SELL
  if (current.tf !== "15m" || !current.side) {
    return;
  }

  try {
    const previous5m = await getPrevious5mSignal(
      CHANNEL_A,
      msg.message_id,
      PREVIOUS_MESSAGE_LOOKBACK
    );

    if (!previous5m) {
      console.log(`[FILTER] M15 ${current.side} ignored: previous M5 not found`);
      return;
    }

    if (previous5m.side !== current.side) {
      console.log(
        `[FILTER] M15 ${current.side} ignored: previous M5=${previous5m.side}`
      );
      return;
    }

    await ctx.telegram.forwardMessage(CHANNEL_B, CHANNEL_A, msg.message_id);
  } catch (err) {
    console.error("[FILTER] Handler error:", err?.message || err);
  }
});

/* ============================================================
   APPLY R-MULTIPLE TP

   Ghi đè TP gốc trong tín hiệu bằng entry ± riskDistance * R.
   Chạy SAU bước MERGE SAME ENTRY.
============================================================ */

function applyRMultipleTp(signal, rMultiple = groupConfig.tpRMultiple) {
  if (!signal || !Array.isArray(signal.orders)) {
    return signal;
  }

  signal.tpRMultiple = rMultiple;

  signal.orders = signal.orders.map((order) => {
    const riskDistance = Math.abs(signal.sl - order.entry);

    // SL == Entry hoặc dữ liệu hỏng => giữ nguyên TP gốc
    if (!Number.isFinite(riskDistance) || riskDistance <= 0) {
      return order;
    }

    const rawTp =
      signal.type === "SELL_LIMIT"
        ? order.entry - riskDistance * rMultiple
        : order.entry + riskDistance * rMultiple;

    return { ...order, tp: Number(rawTp.toFixed(3)) };
  });

  return signal;
}

/* ============================================================
   RISK OVERRIDE TRONG TÍN HIỆU

   Thêm vào cuối tin nhắn (hoặc trên dòng riêng):
     | R A=40 B=400
     | R B=0          (nhóm B bỏ qua lệnh này)
     R: A=30, B=300

   Chỉ áp dụng cho đúng tín hiệu đó, không đổi mặc định.
   Nhóm không tồn tại hoặc vượt maxRiskUsd => KHÔNG gửi lệnh.
============================================================ */

const RISK_OVERRIDE_RE =
  /(?:^|\|)\s*R\s*:?\s+([A-Za-z0-9_]+\s*=\s*\d+(?:[.,]\d+)?(?:[\s,;]+[A-Za-z0-9_]+\s*=\s*\d+(?:[.,]\d+)?)*)\s*$/im;

function extractRiskOverrides(text) {
  const match = text.match(RISK_OVERRIDE_RE);

  if (!match) {
    return { text, overrides: {} };
  }

  const overrides = {};

  for (const [, rawName, rawValue] of match[1].matchAll(
    /([A-Za-z0-9_]+)\s*=\s*(\d+(?:[.,]\d+)?)/g
  )) {
    const name = rawName.toUpperCase();
    const group = groupConfig.groups[name];

    if (!group) {
      return {
        error: `Nhóm không tồn tại trong ghi đè R: ${name}. Nhóm hiện có: ${Object.keys(
          groupConfig.groups
        ).join(", ")}`,
      };
    }

    const value = Number(rawValue.replace(",", "."));

    if (!Number.isFinite(value) || value < 0 || value > group.maxRiskUsd) {
      return {
        error: `R nhóm ${name} = ${rawValue} không hợp lệ. Cho phép 0..${group.maxRiskUsd}$`,
      };
    }

    overrides[name] = value;
  }

  return {
    text: text.replace(match[0], "").trim(),
    overrides,
  };
}

/* ============================================================
   PARSE TRADE SIGNAL

   Server KHÔNG tính lot nữa. Mỗi order mang tỷ trọng w (phần của 1R),
   tổng w = 1. EA tự quy ra lot theo riskMoney của nhóm và broker của nó.

   Phân bổ mặc định:
     1 entry  -> [1]
     2 entry  -> [0.5, 0.5]
     >=3 entry-> 0.4, 0.4, 0 ... 0, 0.2 (giữ đúng logic cũ)

   Nếu tín hiệu ghi lot cụ thể (@giá, risk, lot1, lot2...) thì w được
   suy ra theo tỷ lệ lot × khoảng cách SL. Số risk sau @giá bị bỏ qua.
============================================================ */

function parseNumberList(raw) {
  return raw
    .split("-")
    .map((value) => parseFloat(value.trim()))
    .filter((value) => !Number.isNaN(value));
}

function defaultRiskWeights(n) {
  if (n === 1) {
    return [1];
  }

  if (n === 2) {
    return [0.5, 0.5];
  }

  return Array.from({ length: n }, (_, index) => {
    if (index === 0 || index === 1) {
      return 0.4;
    }

    if (index === n - 1) {
      return 0.2;
    }

    return 0;
  });
}

function parseOrderSignal(text) {
  const symbolMatch = text.match(/^(xauusd[a-z]?|[a-z]{6})/i);

  const symbol = (symbolMatch ? symbolMatch[1] : "XAUUSD").toUpperCase();

  const upperText = text.toUpperCase();

  const type = upperText.includes("BUY")
    ? "BUY_LIMIT"
    : upperText.includes("SELL")
    ? "SELL_LIMIT"
    : null;

  if (!type) {
    return null;
  }

  /* ---------------- ENTRY ---------------- */

  const entryMatch = text.match(/🕛:\s*([\d.\s-]+)/);

  if (!entryMatch) {
    return null;
  }

  const entries = parseNumberList(entryMatch[1]);

  if (!entries.length) {
    return null;
  }

  /* ---------------- SL ---------------- */

  const slMatch = text.match(/🛑:\s*([\d.]+)/);

  if (!slMatch) {
    return null;
  }

  const sl = parseFloat(slMatch[1]);

  if (Number.isNaN(sl)) {
    return null;
  }

  /* ---------------- TP (sẽ bị ghi đè bởi R multiple) ---------------- */

  const tpMatch = text.match(/🎯:\s*([\d.\s-]+)/);

  const tps = tpMatch ? parseNumberList(tpMatch[1]) : [];

  /* ---------------- RISK WEIGHTS ---------------- */

  const n = entries.length;

  const distances = entries.map((entry) =>
    type === "SELL_LIMIT" ? sl - entry : entry - sl
  );

  let weights = defaultRiskWeights(n);

  const lotMatch = text.match(/@[\d.]+,\s*([\d.,\s]+)/);

  if (lotMatch) {
    const nums = lotMatch[1]
      .split(",")
      .map((value) => parseFloat(value.trim()))
      .filter((value) => !Number.isNaN(value));

    // nums[0] là risk cũ (bỏ qua), phần sau là lot cụ thể nếu có
    const explicitLots = nums.slice(1);

    if (explicitLots.length >= n) {
      const riskParts = entries.map(
        (_, index) =>
          Math.max(0, explicitLots[index]) * Math.max(0, distances[index])
      );

      const total = riskParts.reduce((sum, value) => sum + value, 0);

      if (total > 0) {
        weights = riskParts.map((value) => value / total);
      }
    }
  }

  let orders = entries.map((entry, index) => ({
    entry,
    tp: typeof tps[index] === "number" ? tps[index] : null,

    // SL nằm sai phía entry => w = 0, EA sẽ bỏ qua lệnh này
    w: distances[index] > 0 ? weights[index] : 0,
  }));

  /* ---------------- MERGE SAME ENTRY ---------------- */

  if (orders.length >= 2 && orders[0].entry === orders[1].entry) {
    orders = [
      {
        entry: orders[0].entry,
        tp: orders[1].tp ?? orders[0].tp,
        w: orders[0].w + orders[1].w,
      },
      ...orders.slice(2),
    ];
  }

  orders = orders.map((order) => ({
    ...order,
    w: Number(order.w.toFixed(4)),
  }));

  /* ---------------- TP = R MULTIPLE ---------------- */

  return applyRMultipleTp({
    id: Date.now().toString(36),
    symbol,
    type,
    sl,
    orders,
    createdAt: Date.now(),
  });
}

/* ============================================================
   TCP SERVER
============================================================ */

function sendLine(socket, payload) {
  if (!socket || socket.destroyed || !socket.writable) {
    return false;
  }

  const line = typeof payload === "string" ? payload : JSON.stringify(payload);

  return socket.write(`${line}\n`);
}

/*
 * Lệnh vào thị trường: mỗi EA nhận payload riêng
 * với group + riskMoney của nhóm nó.
 */
function broadcastOrder(signal, overrides = {}) {
  const stats = {};

  for (const [name, group] of Object.entries(groupConfig.groups)) {
    const risk = overrides[name] ?? group.riskUsd;

    stats[name] = {
      risk,
      sent: 0,
      skipped: !(risk > 0),
      overridden: name in overrides,
    };
  }

  for (const client of clients) {
    if (!client.authenticated || !client.group) {
      continue;
    }

    const stat = stats[client.group];

    if (!stat || stat.skipped) {
      continue;
    }

    const payload = {
      ...signal,
      group: client.group,
      riskMoney: stat.risk,
    };

    if (sendLine(client.socket, payload)) {
      stat.sent += 1;
    }
  }

  return stats;
}

/*
 * Lệnh sửa mức (SET_BE / SET_SL / SET_TP): không cần risk.
 * group = null => gửi cho tất cả nhóm.
 */
function broadcastCommand(command, group = null) {
  let delivered = 0;

  for (const client of clients) {
    if (!client.authenticated) {
      continue;
    }

    if (group && client.group !== group) {
      continue;
    }

    if (sendLine(client.socket, command)) {
      delivered += 1;
    }
  }

  return delivered;
}

// Tránh log spam khi EA chưa khai báo nhóm cứ 3 giây reconnect một lần
const authWarnAt = new Map();

function warnThrottled(key, message) {
  const now = Date.now();

  if (now - (authWarnAt.get(key) || 0) < 60_000) {
    return;
  }

  authWarnAt.set(key, now);
  console.warn(message);
}

const tcpServer = net.createServer((socket) => {
  socket.setEncoding("utf8");
  socket.setKeepAlive(true, 15_000);
  socket.setNoDelay(true);

  const client = {
    socket,
    authenticated: false,
    buffer: "",
    login: null,
    server: null,
    group: null,
    connectedAt: Date.now(),
    lastSeenAt: Date.now(),
  };

  clients.add(client);

  /* ---------------- AUTH TIMEOUT ---------------- */

  const authTimeout = setTimeout(() => {
    if (!client.authenticated) {
      sendLine(socket, "AUTH_FAILED");
      socket.destroy();
    }
  }, 5_000);

  /* ---------------- RECEIVE DATA ---------------- */

  socket.on("data", (chunk) => {
    client.lastSeenAt = Date.now();
    client.buffer += chunk;

    // Chống buffer tăng vô hạn
    if (client.buffer.length > 1024 * 1024) {
      socket.destroy(new Error("Receive buffer overflow"));
      return;
    }

    while (true) {
      const newlineIndex = client.buffer.indexOf("\n");

      if (newlineIndex < 0) {
        break;
      }

      const line = client.buffer.slice(0, newlineIndex).trim();

      client.buffer = client.buffer.slice(newlineIndex + 1);

      if (!line) {
        continue;
      }

      /* ---------------- PING ---------------- */

      if (line === "PING") {
        sendLine(socket, "PONG");
        continue;
      }

      if (line === "PONG") {
        continue;
      }

      /* ---------------- AUTH ---------------- */

      if (!client.authenticated) {
        try {
          const hello = JSON.parse(line);

          if (hello.type !== "HELLO" || hello.token !== CONFIG.socketToken) {
            sendLine(socket, "AUTH_FAILED");
            socket.destroy();
            return;
          }

          const login = hello.login != null ? String(hello.login) : null;
          const server = hello.server ?? null;
          const group = resolveGroup(login, server);

          if (!group) {
            warnThrottled(
              `${login}@${server}`,
              `[AUTH] Từ chối ${login}@${server}: chưa được gán nhóm trong groups.json`
            );

            sendLine(socket, "AUTH_FAILED");
            socket.destroy();
            return;
          }

          client.authenticated = true;
          client.login = login;
          client.server = server;
          client.group = group;

          clearTimeout(authTimeout);

          console.log(`[AUTH] EA ${login}@${server} -> nhóm ${group}`);

          sendLine(socket, "AUTH_OK");
        } catch {
          sendLine(socket, "AUTH_FAILED");
          socket.destroy();
          return;
        }

        continue;
      }
    }
  });

  /* ---------------- SOCKET ERROR ---------------- */

  socket.on("error", (error) => {
    console.error(`[TCP] Client error: ${error.message}`);
  });

  /* ---------------- SOCKET CLOSE ---------------- */

  socket.on("close", () => {
    clearTimeout(authTimeout);
    clients.delete(client);
  });
});

tcpServer.on("error", (error) => {
  console.error(`[TCP] Server error: ${error.message}`);
});

/* ============================================================
   R TARGETS (nút copy trên Telegram)
============================================================ */

function getRTargets(signal, order, maxR = 5) {
  const riskDistance = Math.abs(signal.sl - order.entry);

  if (!Number.isFinite(riskDistance) || riskDistance <= 0) {
    return [];
  }

  return Array.from({ length: maxR }, (_, index) => {
    const r = index + 1;

    const price =
      signal.type === "SELL_LIMIT"
        ? order.entry - riskDistance * r
        : order.entry + riskDistance * r;

    return { r, price: price.toFixed(3) };
  });
}

/* ============================================================
   TEXT FORMATTERS
============================================================ */

function countOnline(group) {
  let count = 0;

  for (const client of clients) {
    if (client.authenticated && client.group === group) {
      count += 1;
    }
  }

  return count;
}

function formatGroupsText() {
  const lines = Object.entries(groupConfig.groups).map(
    ([name, group]) =>
      `• ${name}: 1R = ${group.riskUsd}$ (max ${group.maxRiskUsd}$) · ${countOnline(
        name
      )} EA online`
  );

  return (
    `💰 R theo nhóm:\n${lines.join("\n")}\n` +
    `🎯 TP: ${groupConfig.tpRMultiple}R`
  );
}

function formatEaList() {
  const list = [...clients].filter((client) => client.authenticated);

  if (!list.length) {
    return "Không có EA nào đang kết nối.";
  }

  return (
    "🖥 EA đang kết nối:\n" +
    list
      .map((client) => `• ${client.group} · ${client.login}@${client.server}`)
      .join("\n")
  );
}

function formatSignal(signal, stats) {
  const side = signal.type === "SELL_LIMIT" ? "SELL" : "BUY";

  const groupParts = Object.entries(stats).map(([name, stat]) => {
    const mark = stat.overridden ? "✏️" : "";

    return stat.skipped
      ? `${name}${mark}: bỏ qua`
      : `${name}${mark} (${stat.risk}$): ${stat.sent} EA`;
  });

  const weightParts = signal.orders.map(
    (order, index) => `E${index + 1} ${Math.round(order.w * 100)}%R`
  );

  return [
    `📡 ${signal.symbol} ${side}, 🎯 TP=${signal.tpRMultiple}R`,
    `👥 ${groupParts.join(" · ")}`,
    `⚖️ ${weightParts.join(", ")}`,
  ].join("\n");
}

/* ============================================================
   PRIVATE MESSAGE / TRADE COMMANDS

   clear
   /tpr | /tpr 2.5
   /r   | /r A 25          (đổi R mặc định của nhóm, 0 = tạm dừng nhóm)
   /ea                     (liệt kê EA đang kết nối)
   /reload                 (đọc lại groups.json)
   be [nhóm]
   sl <giá> [nhóm]
   tp <giá> [nhóm]
   <tín hiệu> [| R A=40 B=400]
============================================================ */

async function dispatchCommand(ctx, command, group) {
  const delivered = broadcastCommand(command, group);

  if (delivered > 0) {
    await ctx.react("👍");
    return;
  }

  await ctx.reply(
    group
      ? `Không có EA nào của nhóm ${group} đang kết nối.`
      : "Không có EA nào đang kết nối TCP."
  );
}

bot.on("text", async (ctx) => {
  // Không cho channel/group lọt vào handler đặt lệnh.
  if (!ctx.from || !ctx.chat) {
    return;
  }

  if (ctx.chat.type !== "private") {
    return;
  }

  if (ctx.from.id !== ALLOWED_USER_ID || ctx.chat.id !== ALLOWED_USER_ID) {
    // Người khác không có quyền trade, nhưng bot vẫn trả lời hướng dẫn tin tức.
    await forexNews.sendHelp(ctx.chat.id);
    return;
  }

  const originalText = ctx.message?.text?.trim();

  if (!originalText) {
    return;
  }

  const normalizedText = originalText.toLowerCase();

  try {
    /* ======================== CLEAR ======================== */

    if (normalizedText === "clear") {
      await ctx.react("👍");
      return;
    }

    /* ======================== TP R MULTIPLE ======================== */

    if (normalizedText === "tpr" || normalizedText === "/tpr") {
      await ctx.reply(
        `🎯 TP hiện tại: ${groupConfig.tpRMultiple}R\n` +
          `Đổi bằng: /tpr <số>  (ví dụ /tpr 2)`
      );
      return;
    }

    const tprMatch = normalizedText.match(/^\/?tpr\s+(\d+(?:[.,]\d+)?)$/);

    if (tprMatch) {
      const value = Number(tprMatch[1].replace(",", "."));

      if (!Number.isFinite(value) || value <= 0 || value > TP_R_MULTIPLE_MAX) {
        await ctx.reply(
          `Hệ số R không hợp lệ. Cho phép: 0 < R <= ${TP_R_MULTIPLE_MAX}.`
        );
        return;
      }

      const previous = groupConfig.tpRMultiple;

      groupConfig.tpRMultiple = value;

      const saved = trySaveGroupConfig();

      console.log(`[TP] R multiple: ${previous} -> ${value}`);

      await ctx.reply(
        `✅ TP mặc định: ${previous}R → ${value}R\n` +
          `Áp dụng cho các tín hiệu gửi sau lệnh này.` +
          (saved ? "" : SAVE_WARN)
      );
      return;
    }

    /* ======================== R THEO NHÓM ======================== */

    if (normalizedText === "r" || normalizedText === "/r") {
      await ctx.reply(
        `${formatGroupsText()}\n\n` +
          `Đổi mặc định: /r <nhóm> <usd>  (ví dụ /r A 25, /r B 0 để tạm dừng)\n` +
          `Ghi đè 1 lệnh: thêm "| R A=40 B=400" vào cuối tín hiệu`
      );
      return;
    }

    const rMatch = normalizedText.match(
      /^\/?r\s+([a-z0-9_]+)\s+(\d+(?:[.,]\d+)?)$/
    );

    if (rMatch) {
      const { group: name, error } = parseGroupArg(rMatch[1]);

      if (error) {
        await ctx.reply(error);
        return;
      }

      const group = groupConfig.groups[name];
      const value = Number(rMatch[2].replace(",", "."));

      if (!Number.isFinite(value) || value < 0 || value > group.maxRiskUsd) {
        await ctx.reply(
          `R nhóm ${name} không hợp lệ. Cho phép 0..${group.maxRiskUsd}$ ` +
            `(sửa maxRiskUsd trong groups.json rồi /reload nếu cần cao hơn).`
        );
        return;
      }

      const previous = group.riskUsd;

      group.riskUsd = value;

      const saved = trySaveGroupConfig();

      console.log(`[RISK] Group ${name}: ${previous}$ -> ${value}$`);

      await ctx.reply(
        `✅ Nhóm ${name}: 1R = ${previous}$ → ${value}$` +
          (value === 0 ? " (tạm dừng nhóm)" : "") +
          (saved ? "" : SAVE_WARN)
      );
      return;
    }

    /* ======================== EA LIST / RELOAD ======================== */

    if (normalizedText === "ea" || normalizedText === "/ea") {
      await ctx.reply(formatEaList());
      return;
    }

    if (normalizedText === "reload" || normalizedText === "/reload") {
      try {
        const kicked = reloadGroupConfig();

        await ctx.reply(
          `🔄 Đã đọc lại groups.json\n${formatGroupsText()}` +
            (kicked ? `\n⚠️ Đã ngắt ${kicked} EA không còn nhóm.` : "")
        );
      } catch (error) {
        await ctx.reply(
          `❌ groups.json lỗi, giữ cấu hình cũ:\n${error?.message || error}`
        );
      }
      return;
    }

    /* ======================== BREAK EVEN ======================== */

    const beMatch = normalizedText.match(
      /^\/?(?:be|set[ _]be)(?:\s+([a-z0-9_]+))?$/
    );

    if (beMatch) {
      const { group, error } = parseGroupArg(beMatch[1]);

      if (error) {
        await ctx.reply(error);
        return;
      }

      await dispatchCommand(
        ctx,
        { symbol: "XAUUSD", type: "SET_BE", createdAt: Date.now() },
        group
      );
      return;
    }

    /* ======================== SET SL / SET TP ======================== */

    const levelMatch = normalizedText.match(
      /^\/?(sl|tp)\s+(\d+(?:[.,]\d+)?)(?:\s+([a-z0-9_]+))?$/
    );

    if (levelMatch) {
      const kind = levelMatch[1].toUpperCase();
      const price = Number(levelMatch[2].replace(",", "."));

      if (!Number.isFinite(price) || price <= 0) {
        await ctx.reply(`Giá ${kind} không hợp lệ.`);
        return;
      }

      const { group, error } = parseGroupArg(levelMatch[3]);

      if (error) {
        await ctx.reply(error);
        return;
      }

      await dispatchCommand(
        ctx,
        { symbol: "XAUUSD", type: `SET_${kind}`, price, createdAt: Date.now() },
        group
      );
      return;
    }

    /* ======================== NEW ORDER ======================== */

    const {
      text: signalText,
      overrides,
      error: overrideError,
    } = extractRiskOverrides(originalText);

    if (overrideError) {
      await ctx.reply(`⚠️ ${overrideError}\nTín hiệu KHÔNG được gửi.`);
      return;
    }

    const signal = parseOrderSignal(signalText);

    if (!signal) {
      await forexNews.sendHelp(ctx.chat.id);
      return;
    }

    if (!signal.orders.some((order) => order.w > 0)) {
      await ctx.reply(
        "⚠️ SL nằm sai phía so với entry, không có lệnh hợp lệ. Tín hiệu KHÔNG được gửi."
      );
      return;
    }

    const stats = broadcastOrder(signal, overrides);

    console.log(
      `[ORDER] ${signal.id} ${signal.type} sl=${signal.sl} ` +
        `orders=${JSON.stringify(signal.orders)} stats=${JSON.stringify(stats)}`
    );

    /* ---------------- INLINE KEYBOARD ---------------- */

    const keyboard = [];
    const tpPrefix = "TP ";

    signal.orders.forEach((order, index) => {
      const rTargets = getRTargets(signal, order, 5);

      keyboard.push([
        {
          text: `📥 E${index + 1} ${order.entry}`,
          copy_text: { text: String(order.entry) },
        },
        {
          text: `🎯 TP ${order.tp ?? "N/A"}`,
          copy_text: { text: tpPrefix + String(order.tp ?? "") },
        },
      ]);

      // SL == Entry => riskDistance = 0 => không có R targets
      if (rTargets.length >= 5) {
        keyboard.push([
          {
            text: `1R ${rTargets[0].price}`,
            copy_text: { text: tpPrefix + rTargets[0].price },
          },
          {
            text: `2R ${rTargets[1].price}`,
            copy_text: { text: tpPrefix + rTargets[1].price },
          },
        ]);

        keyboard.push([
          {
            text: `3R ${rTargets[2].price}`,
            copy_text: { text: tpPrefix + rTargets[2].price },
          },
          {
            text: `5R ${rTargets[4].price}`,
            copy_text: { text: tpPrefix + rTargets[4].price },
          },
        ]);
      }
    });

    keyboard.push([
      {
        text: `🛑 SL ${signal.sl}`,
        copy_text: { text: "SL " + String(signal.sl) },
      },
    ]);

    await ctx.reply(formatSignal(signal, stats), {
      reply_to_message_id: ctx.message.message_id,
      reply_markup: { inline_keyboard: keyboard },
    });
  } catch (error) {
    console.error("[TRADE] Handler error:", error?.message || error);
  }
});

/* ============================================================
   HTTP STATUS API
============================================================ */

app.get("/ping", (_req, res) => {
  res.send("pong");
});

app.get("/status", (_req, res) => {
  const connectedClients = [...clients].map((client) => ({
    authenticated: client.authenticated,
    login: client.login,
    server: client.server,
    group: client.group,
    remoteAddress: client.socket.remoteAddress,
    connectedAt: client.connectedAt,
    lastSeenAt: client.lastSeenAt,
  }));

  res.json({
    ok: true,
    tpRMultiple: groupConfig?.tpRMultiple,
    groups: groupConfig?.groups,
    connectedEA: connectedClients.filter((client) => client.authenticated)
      .length,
    clients: connectedClients,
  });
});

/* ============================================================
   TCP HEARTBEAT
============================================================ */

setInterval(() => {
  const now = Date.now();

  for (const client of clients) {
    if (client.socket.destroyed) {
      continue;
    }

    // Không phản hồi > 90s => loại connection.
    if (now - client.lastSeenAt > 90_000) {
      client.socket.destroy();
      continue;
    }

    if (client.authenticated) {
      sendLine(client.socket, "PING");
    }
  }
}, 30_000).unref();

/* ============================================================
   START
============================================================ */

async function start() {
  console.log("🚀 Starting combined app...");

  /* ---------------- Groups ---------------- */

  groupConfig = readGroupConfigFile();

  console.log(`🎯 TP override: ${groupConfig.tpRMultiple}R`);

  for (const [name, group] of Object.entries(groupConfig.groups)) {
    console.log(
      `👥 Group ${name}: 1R=${group.riskUsd}$ (max ${group.maxRiskUsd}$)`
    );
  }

  console.log(
    `📒 Accounts: ${Object.keys(groupConfig.accounts).length}` +
      ` | defaultGroup: ${groupConfig.defaultGroup ?? "none"}`
  );

  /* ---------------- GramJS ---------------- */

  await userClient.connect();

  console.log("👤 Telegram user client connected");

  /* ---------------- TCP ---------------- */

  tcpServer.listen(CONFIG.tcpPort, CONFIG.tcpHost, () => {
    console.log(`🔌 TCP server running at ${CONFIG.tcpHost}:${CONFIG.tcpPort}`);
  });

  /* ---------------- HTTP ---------------- */

  httpServer = app.listen(CONFIG.httpPort, "0.0.0.0", () => {
    console.log(`🌐 Status API running at http://0.0.0.0:${CONFIG.httpPort}`);
  });

  /* ---------------- Forex Factory News ---------------- */

  await forexNews.start();

  console.log("📰 Forex Factory news module running");

  /* ---------------- Telegram Bot ---------------- */

  bot.launch({ dropPendingUpdates: true }).catch((error) => {
    console.error("Telegram bot launch error:", error?.message || error);
    process.exit(1);
  });

  console.log("🤖 Telegram bot running");
  console.log("✅ Combined app started successfully");
}

/* ============================================================
   SHUTDOWN
============================================================ */

async function shutdown(signal) {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;

  console.log(`🛑 Shutting down (${signal})...`);

  try {
    try {
      forexNews.stop();
    } catch (error) {
      console.error("Forex news stop error:", error?.message || error);
    }

    try {
      bot.stop(signal);
    } catch {
      // Ignore if bot was not started
    }

    for (const client of clients) {
      try {
        client.socket.destroy();
      } catch {
        // ignore
      }
    }

    clients.clear();

    try {
      tcpServer.close();
    } catch {
      // ignore
    }

    try {
      if (httpServer) {
        httpServer.close();
      }
    } catch {
      // ignore
    }

    try {
      if (typeof userClient.disconnect === "function") {
        await userClient.disconnect();
      }
    } catch (error) {
      console.error("GramJS disconnect error:", error?.message || error);
    }
  } finally {
    process.exit(0);
  }
}

/* ============================================================
   PROCESS EVENTS
============================================================ */

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));

process.on("unhandledRejection", (reason) => {
  console.error("UNHANDLED REJECTION:");
  console.error(reason);
});

process.on("uncaughtException", (error) => {
  console.error("UNCAUGHT EXCEPTION:");
  console.error(error);
  process.exit(1);
});

/* ============================================================
   RUN
============================================================ */

start().catch((error) => {
  console.error("Startup error:", error?.message || error);
  process.exit(1);
});
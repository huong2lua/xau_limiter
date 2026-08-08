require("dotenv").config();
const { Telegraf } = require("telegraf");
const express = require("express");
const net = require("net");

const bot = new Telegraf(process.env.BOT_TOKEN);
const app = express();

const ALLOWED_USER_ID = 5978153872;
const HTTP_PORT = Number(process.env.HTTP_PORT || 3001);
const TCP_PORT = Number(process.env.TCP_PORT || 3002);
const TCP_HOST = process.env.TCP_HOST || "0.0.0.0";
const SOCKET_TOKEN = process.env.SOCKET_TOKEN || "CHANGE_ME_STRONG_TOKEN";

const clients = new Set();

/* ================= PARSE TELEGRAM SIGNAL ================= */

function parseSignal(text) {
  const symbolMatch = text.match(/^(xauusd[a-z]?|[a-z]{6})/i);
  const symbol = (symbolMatch ? symbolMatch[1] : "XAUUSD").toUpperCase();

  const upperText = text.toUpperCase();
  const type = upperText.includes("BUY")
    ? "BUY_LIMIT"
    : upperText.includes("SELL")
    ? "SELL_LIMIT"
    : null;

  if (!type) return null;

  const entryMatch = text.match(/🕛:\s*([\d.\s-]+)/);
  if (!entryMatch) return null;

  const entries = entryMatch[1]
    .split("-")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !Number.isNaN(v));

  if (!entries.length) return null;

  const slMatch = text.match(/🛑:\s*([\d.]+)/);
  if (!slMatch) return null;

  const sl = parseFloat(slMatch[1]);
  if (Number.isNaN(sl)) return null;

  const tpMatch = text.match(/🎯:\s*([\d.\s-]+)/);
  if (!tpMatch) return null;

  const tps = tpMatch[1]
    .split("-")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !Number.isNaN(v));

  const lotMatch = text.match(/@[\d.]+,\s*([\d.,\s]+)/);
  if (!lotMatch) return null;

  const nums = lotMatch[1]
    .split(",")
    .map((v) => parseFloat(v.trim()))
    .filter((v) => !Number.isNaN(v));

  const n = entries.length;
  if (nums.length < 1) return null;

  const totalRisk = nums[0];
  const lotsCandidate = nums.slice(1);
  let lots = [];

  if (lotsCandidate.length >= n) {
    lots = lotsCandidate.slice(0, n).map((x) => Number(x.toFixed(3)));
  } else {
    let risks = [];

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
        return 0;
      });
    }

    lots = entries.map((entry, i) => {
      const distance = type === "SELL_LIMIT" ? sl - entry : entry - sl;
      if (distance <= 0) return 0;

      const lot = risks[i] / (distance * 100);
      return Math.max(0, Number(lot.toFixed(3)));
    });
  }

  lots = Array.from(
    { length: n },
    (_, i) => (typeof lots[i] === "number" ? lots[i] : 0)
  );

  let orders = entries.map((entry, i) => ({
    entry,
    tp: typeof tps[i] === "number" ? tps[i] : null,
    lot: lots[i],
  }));

  if (orders.length >= 2 && orders[0].entry === orders[1].entry) {
    const mergedOrder = {
      entry: orders[0].entry,
      lot: Number((orders[0].lot + orders[1].lot).toFixed(3)),
      tp: orders[1].tp ?? orders[0].tp,
    };

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

/* ================= TCP PUSH SERVER ================= */

function sendLine(socket, payload) {
  if (!socket || socket.destroyed || !socket.writable) return false;

  const line = typeof payload === "string"
    ? payload
    : JSON.stringify(payload);

  return socket.write(`${line}\n`);
}

function broadcastSignal(signal) {
  let delivered = 0;

  for (const client of clients) {
    if (!client.authenticated) continue;

    if (sendLine(client.socket, signal)) {
      delivered += 1;
    }
  }

  // console.log(
  //   `[TCP] Broadcast ${signal.type} to ${delivered}/${clients.size} connected EA(s)`
  // );

  return delivered;
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
    connectedAt: Date.now(),
    lastSeenAt: Date.now(),
  };

  clients.add(client);

  // console.log(
  //   `[TCP] Connected: ${socket.remoteAddress}:${socket.remotePort}`
  // );

  const authTimeout = setTimeout(() => {
    if (!client.authenticated) {
      sendLine(socket, "AUTH_FAILED");
      socket.destroy();
    }
  }, 5_000);

  socket.on("data", (chunk) => {
    client.lastSeenAt = Date.now();
    client.buffer += chunk;

    if (client.buffer.length > 1024 * 1024) {
      socket.destroy(new Error("Receive buffer overflow"));
      return;
    }

    while (true) {
      const newlineIndex = client.buffer.indexOf("\n");
      if (newlineIndex < 0) break;

      const line = client.buffer.slice(0, newlineIndex).trim();
      client.buffer = client.buffer.slice(newlineIndex + 1);

      if (!line) continue;

      if (line === "PING") {
        sendLine(socket, "PONG");
        continue;
      }

      if (line === "PONG") {
        continue;
      }

      if (!client.authenticated) {
        try {
          const hello = JSON.parse(line);

          if (
            hello.type !== "HELLO" ||
            hello.token !== SOCKET_TOKEN
          ) {
            sendLine(socket, "AUTH_FAILED");
            socket.destroy();
            return;
          }

          client.authenticated = true;
          client.login = hello.login ?? null;
          client.server = hello.server ?? null;
          clearTimeout(authTimeout);

          sendLine(socket, "AUTH_OK");

          // console.log(
          //   `[TCP] Authenticated: login=${client.login}, server=${client.server}`
          // );
        } catch {
          sendLine(socket, "AUTH_FAILED");
          socket.destroy();
        }

        continue;
      }
    }
  });

  socket.on("error", (error) => {
    console.error(`[TCP] Client error: ${error.message}`);
  });

  socket.on("close", () => {
    clearTimeout(authTimeout);
    clients.delete(client);

    // console.log(
    //   `[TCP] Disconnected: login=${client.login ?? "unknown"}`
    // );
  });
});

tcpServer.on("error", (error) => {
  console.error(`[TCP] Server error: ${error.message}`);
  process.exitCode = 1;
});

tcpServer.listen(TCP_PORT, TCP_HOST, () => {
  console.log(`TCP signal server running at ${TCP_HOST}:${TCP_PORT}`);
});

/* ================= TELEGRAM BOT ================= */

function getRTargets(signal, order, maxR = 5) {
  const riskDistance = Math.abs(signal.sl - order.entry);

  if (!Number.isFinite(riskDistance) || riskDistance <= 0) {
    return [];
  }

  return Array.from({ length: maxR }, (_, i) => {
    const r = i + 1;

    const price =
      signal.type === "SELL_LIMIT"
        ? order.entry - riskDistance * r
        : order.entry + riskDistance * r;

    return {
      r,
      price: price.toFixed(3),
    };
  });
}

function c(value) {
  return `<code>${value}</code>`;
}

function formatSignal(signal, delivered) {
  let text = `📡: ${signal.symbol}\n`;
  text += `🛑 ${c(`SL ` +signal.sl)}\n`;
  text += `🖥 EA nhận: ${delivered}\n\n`;

  signal.orders.forEach((order, index) => {
    const rTargets = getRTargets(signal, order, 5);

    const rText = rTargets
      .map((item) => `${item.r}R: ${c(item.price)}`)
      .join(" | ");

    text += `📥 Entry ${index + 1}: ${c(order.entry)}\n`;
    text += `   • Lot: ${c(order.lot)}\n`;
    text += `   • TP: ${c(order.tp ?? "N/A")}\n`;
    text += `   • ${rText}\n\n`;
  });

  return text.trim();
}

bot.on("text", async (ctx) => {
  if (
    ctx.from.id !== ALLOWED_USER_ID ||
    ctx.chat.id !== ALLOWED_USER_ID
  ) {
    return;
  }

  const originalText = ctx.message.text.trim();
  const normalizedText = originalText.toLowerCase();

  if (normalizedText === "clear") {
    await ctx.react("👍");
    return;
  }

  if (
    normalizedText === "be" ||
    normalizedText === "/be" ||
    normalizedText === "set be" ||
    normalizedText === "set_be"
  ) {
    const signal = {
      symbol: "XAUUSD",
      type: "SET_BE",
      createdAt: Date.now(),
    };

    const delivered = broadcastSignal(signal);

    if (delivered > 0) {
      await ctx.react("👍");
    } else {
      await ctx.reply("Không có EA nào đang kết nối TCP.");
    }

    return;
  }

  const slMatch = normalizedText.match(
    /^\/?sl\s+(\d+(?:[.,]\d+)?)$/i
  );

  if (slMatch) {
    const price = Number(slMatch[1].replace(",", "."));

    if (!Number.isFinite(price) || price <= 0) {
      await ctx.reply("Giá SL không hợp lệ.");
      return;
    }

    const signal = {
      symbol: "XAUUSD",
      type: "SET_SL",
      price,
      createdAt: Date.now(),
    };

    const delivered = broadcastSignal(signal);

    if (delivered > 0) {
      await ctx.react("👍");
    } else {
      await ctx.reply("Không có EA nào đang kết nối TCP.");
    }

    return;
  }

  const tpMatch = normalizedText.match(
    /^\/?tp\s+(\d+(?:[.,]\d+)?)$/i
  );

  if (tpMatch) {
    const price = Number(tpMatch[1].replace(",", "."));

    if (!Number.isFinite(price) || price <= 0) {
      await ctx.reply("Giá TP không hợp lệ.");
      return;
    }

    const signal = {
      symbol: "XAUUSD",
      type: "SET_TP",
      price,
      createdAt: Date.now(),
    };

    const delivered = broadcastSignal(signal);

    if (delivered > 0) {
      await ctx.react("👍");
    } else {
      await ctx.reply("Không có EA nào đang kết nối TCP.");
    }

    return;
  }

  const signal = parseSignal(originalText);
  if (!signal) return;

  const delivered = broadcastSignal(signal);

  await ctx.reply(formatSignal(signal, delivered), {
    reply_to_message_id: ctx.message.message_id,
    parse_mode: "HTML",
  });
});

/* ================= STATUS API ================= */

app.get("/ping", (_req, res) => {
  res.send("pong");
});

app.get("/status", (_req, res) => {
  const connectedClients = [...clients].map((client) => ({
    authenticated: client.authenticated,
    // login: client.login,
    server: client.server,
    remoteAddress: client.socket.remoteAddress,
    connectedAt: client.connectedAt,
    lastSeenAt: client.lastSeenAt,
  }));

  res.json({
    ok: true,
    connectedEA: connectedClients.filter((client) => client.authenticated).length,
    clients: connectedClients,
  });
});

app.listen(HTTP_PORT, "0.0.0.0", () => {
  console.log(`Status API running at http://0.0.0.0:${HTTP_PORT}`);
});

/* ================= HEARTBEAT / CLEANUP ================= */

setInterval(() => {
  const now = Date.now();

  for (const client of clients) {
    if (client.socket.destroyed) continue;

    if (now - client.lastSeenAt > 90_000) {
      client.socket.destroy();
      continue;
    }

    if (client.authenticated) {
      sendLine(client.socket, "PING");
    }
  }
}, 30_000).unref();

async function shutdown(signal) {
  console.log(`Received ${signal}, shutting down...`);

  bot.stop(signal);

  for (const client of clients) {
    client.socket.destroy();
  }

  tcpServer.close();

  process.exit(0);
}

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));

bot.launch()
  .then(() => {
    console.log("Telegram bot started");
  })
  .catch((error) => {
    console.error("Telegram bot launch failed:", error);
    process.exit(1);
  });

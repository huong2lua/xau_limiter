require("dotenv").config();

const { Telegraf } = require("telegraf");
const { TelegramClient } = require("telegram");
const { StringSession } = require("telegram/sessions");
const express = require("express");
const net = require("net");

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
   CLIENTS / SERVERS
============================================================ */

const bot = new Telegraf(CONFIG.botToken);

const userClient = new TelegramClient(
  new StringSession(CONFIG.session),
  CONFIG.apiId,
  CONFIG.apiHash,
  {
    connectionRetries: 5,
  }
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
   FILTER SIGNAL
   CHANNEL_A: M5 -> M15
============================================================ */

function parseFilterSignal(text = "") {
  const tf =
    text.match(/\b(5m|15m)\b/i)?.[1]?.toLowerCase() ?? null;

  const side =
    text.match(/\b(BUY|SELL)\b/i)?.[1]?.toUpperCase() ?? null;

  return {
    tf,
    side,
  };
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
    const text =
      typeof message?.message === "string"
        ? message.message
        : "";

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

  if (!msg) {
    return;
  }

  // Chỉ xử lý CHANNEL_A
  if (!isFromChannel(msg, CHANNEL_A)) {
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
      console.log(
        `[FILTER] M15 ${current.side} ignored: previous M5 not found`
      );

      return;
    }

    if (previous5m.side !== current.side) {
      console.log(
        `[FILTER] M15 ${current.side} ignored: previous M5=${previous5m.side}`
      );

      return;
    }

    await ctx.telegram.forwardMessage(
      CHANNEL_B,
      CHANNEL_A,
      msg.message_id
    );

    console.log(
      `🔥 Forwarded M15 ${current.side}` +
      ` | msgId=${msg.message_id}` +
      ` | matched M5 msgId=${previous5m.messageId}`
    );
  } catch (err) {
    console.error(
      "[FILTER] Handler error:",
      err?.message || err
    );
  }
});

/* ============================================================
   PARSE TRADE SIGNAL
============================================================ */

function parseOrderSignal(text) {
  const symbolMatch = text.match(
    /^(xauusd[a-z]?|[a-z]{6})/i
  );

  const symbol = (
    symbolMatch
      ? symbolMatch[1]
      : "XAUUSD"
  ).toUpperCase();

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

  const entryMatch = text.match(
    /🕛:\s*([\d.\s-]+)/
  );

  if (!entryMatch) {
    return null;
  }

  const entries = entryMatch[1]
    .split("-")
    .map((value) => parseFloat(value.trim()))
    .filter((value) => !Number.isNaN(value));

  if (!entries.length) {
    return null;
  }

  /* ---------------- SL ---------------- */

  const slMatch = text.match(
    /🛑:\s*([\d.]+)/
  );

  if (!slMatch) {
    return null;
  }

  const sl = parseFloat(slMatch[1]);

  if (Number.isNaN(sl)) {
    return null;
  }

  /* ---------------- TP ---------------- */

  const tpMatch = text.match(
    /🎯:\s*([\d.\s-]+)/
  );

  if (!tpMatch) {
    return null;
  }

  const tps = tpMatch[1]
    .split("-")
    .map((value) => parseFloat(value.trim()))
    .filter((value) => !Number.isNaN(value));

  /* ---------------- RISK / LOT ---------------- */

  const lotMatch = text.match(
    /@[\d.]+,\s*([\d.,\s]+)/
  );

  if (!lotMatch) {
    return null;
  }

  const nums = lotMatch[1]
    .split(",")
    .map((value) => parseFloat(value.trim()))
    .filter((value) => !Number.isNaN(value));

  const n = entries.length;

  if (nums.length < 1) {
    return null;
  }

  const totalRisk = nums[0];

  const lotsCandidate = nums.slice(1);

  let lots = [];

  if (lotsCandidate.length >= n) {
    lots = lotsCandidate
      .slice(0, n)
      .map((value) =>
        Number(value.toFixed(3))
      );
  } else {
    let risks = [];

    if (n === 1) {
      risks = [
        totalRisk,
      ];
    } else if (n === 2) {
      risks = [
        totalRisk / 2,
        totalRisk / 2,
      ];
    } else {
      const riskFirstTwo =
        totalRisk * 0.8;

      const riskEachFirst =
        riskFirstTwo / 2;

      const riskLast =
        totalRisk * 0.2;

      risks = entries.map(
        (_, index) => {
          if (
            index === 0 ||
            index === 1
          ) {
            return riskEachFirst;
          }

          if (index === n - 1) {
            return riskLast;
          }

          return 0;
        }
      );
    }

    lots = entries.map(
      (entry, index) => {
        const distance =
          type === "SELL_LIMIT"
            ? sl - entry
            : entry - sl;

        if (distance <= 0) {
          return 0;
        }

        const lot =
          risks[index] /
          (distance * 100);

        return Math.max(
          0,
          Number(lot.toFixed(3))
        );
      }
    );
  }

  lots = Array.from(
    {
      length: n,
    },
    (_, index) =>
      typeof lots[index] === "number"
        ? lots[index]
        : 0
  );

  let orders = entries.map(
    (entry, index) => ({
      entry,

      tp:
        typeof tps[index] === "number"
          ? tps[index]
          : null,

      lot: lots[index],
    })
  );

  /* ---------------- MERGE SAME ENTRY ---------------- */

  if (
    orders.length >= 2 &&
    orders[0].entry === orders[1].entry
  ) {
    const mergedOrder = {
      entry: orders[0].entry,

      lot: Number(
        (
          orders[0].lot +
          orders[1].lot
        ).toFixed(3)
      ),

      tp:
        orders[1].tp ??
        orders[0].tp,
    };

    orders = [
      mergedOrder,
      ...orders.slice(2),
    ];
  }

  return {
    symbol,
    type,
    sl,
    orders,
    createdAt: Date.now(),
  };
}

/* ============================================================
   TCP SERVER
============================================================ */

function sendLine(socket, payload) {
  if (
    !socket ||
    socket.destroyed ||
    !socket.writable
  ) {
    return false;
  }

  const line =
    typeof payload === "string"
      ? payload
      : JSON.stringify(payload);

  return socket.write(
    `${line}\n`
  );
}

function broadcastSignal(signal) {
  let delivered = 0;

  for (const client of clients) {
    if (!client.authenticated) {
      continue;
    }

    if (
      sendLine(
        client.socket,
        signal
      )
    ) {
      delivered += 1;
    }
  }

  return delivered;
}

const tcpServer = net.createServer(
  (socket) => {
    socket.setEncoding("utf8");

    socket.setKeepAlive(
      true,
      15_000
    );

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

    /* ---------------- AUTH TIMEOUT ---------------- */

    const authTimeout =
      setTimeout(() => {
        if (
          !client.authenticated
        ) {
          sendLine(
            socket,
            "AUTH_FAILED"
          );

          socket.destroy();
        }
      }, 5_000);

    /* ---------------- RECEIVE DATA ---------------- */

    socket.on(
      "data",
      (chunk) => {
        client.lastSeenAt =
          Date.now();

        client.buffer += chunk;

        // Chống buffer tăng vô hạn
        if (
          client.buffer.length >
          1024 * 1024
        ) {
          socket.destroy(
            new Error(
              "Receive buffer overflow"
            )
          );

          return;
        }

        while (true) {
          const newlineIndex =
            client.buffer.indexOf(
              "\n"
            );

          if (
            newlineIndex < 0
          ) {
            break;
          }

          const line =
            client.buffer
              .slice(
                0,
                newlineIndex
              )
              .trim();

          client.buffer =
            client.buffer.slice(
              newlineIndex + 1
            );

          if (!line) {
            continue;
          }

          /* ---------------- PING ---------------- */

          if (line === "PING") {
            sendLine(
              socket,
              "PONG"
            );

            continue;
          }

          if (line === "PONG") {
            continue;
          }

          /* ---------------- AUTH ---------------- */

          if (
            !client.authenticated
          ) {
            try {
              const hello =
                JSON.parse(line);

              if (
                hello.type !==
                  "HELLO" ||
                hello.token !==
                  CONFIG.socketToken
              ) {
                sendLine(
                  socket,
                  "AUTH_FAILED"
                );

                socket.destroy();

                return;
              }

              client.authenticated =
                true;

              client.login =
                hello.login ?? null;

              client.server =
                hello.server ?? null;

              clearTimeout(
                authTimeout
              );

              sendLine(
                socket,
                "AUTH_OK"
              );
            } catch {
              sendLine(
                socket,
                "AUTH_FAILED"
              );

              socket.destroy();

              return;
            }

            continue;
          }
        }
      }
    );

    /* ---------------- SOCKET ERROR ---------------- */

    socket.on(
      "error",
      (error) => {
        console.error(
          `[TCP] Client error: ${error.message}`
        );
      }
    );

    /* ---------------- SOCKET CLOSE ---------------- */

    socket.on(
      "close",
      () => {
        clearTimeout(
          authTimeout
        );

        clients.delete(
          client
        );
      }
    );
  }
);

tcpServer.on(
  "error",
  (error) => {
    console.error(
      `[TCP] Server error: ${error.message}`
    );
  }
);

/* ============================================================
   R TARGETS
============================================================ */

function getRTargets(
  signal,
  order,
  maxR = 5
) {
  const riskDistance =
    Math.abs(
      signal.sl -
      order.entry
    );

  if (
    !Number.isFinite(
      riskDistance
    ) ||
    riskDistance <= 0
  ) {
    return [];
  }

  return Array.from(
    {
      length: maxR,
    },
    (_, index) => {
      const r =
        index + 1;

      const price =
        signal.type ===
        "SELL_LIMIT"
          ? order.entry -
            riskDistance * r
          : order.entry +
            riskDistance * r;

      return {
        r,

        price:
          price.toFixed(3),
      };
    }
  );
}

function formatSignal(
  signal,
  delivered
) {
  return (
    `📡 ${signal.symbol}` +
    `  |  🖥 EA nhận: ${delivered}`
  );
}

/* ============================================================
   PRIVATE MESSAGE / TRADE COMMANDS
============================================================ */

bot.on("text", async (ctx) => {
  /*
   * Quan trọng khi dùng chung bot:
   *
   * Không cho channel/group lọt vào
   * handler đặt lệnh.
   */

  if (
    !ctx.from ||
    !ctx.chat
  ) {
    return;
  }

  if (
    ctx.chat.type !== "private"
  ) {
    return;
  }

  if (
    ctx.from.id !==
      ALLOWED_USER_ID ||
    ctx.chat.id !==
      ALLOWED_USER_ID
  ) {
    return;
  }

  const originalText =
    ctx.message?.text?.trim();

  if (!originalText) {
    return;
  }

  const normalizedText =
    originalText.toLowerCase();

  try {
    /* ========================================================
       CLEAR
    ======================================================== */

    if (
      normalizedText ===
      "clear"
    ) {
      await ctx.react("👍");

      return;
    }

    /* ========================================================
       BREAK EVEN
    ======================================================== */

    if (
      normalizedText ===
        "be" ||
      normalizedText ===
        "/be" ||
      normalizedText ===
        "set be" ||
      normalizedText ===
        "set_be"
    ) {
      const signal = {
        symbol: "XAUUSD",

        type: "SET_BE",

        createdAt:
          Date.now(),
      };

      const delivered =
        broadcastSignal(
          signal
        );

      if (
        delivered > 0
      ) {
        await ctx.react(
          "👍"
        );
      } else {
        await ctx.reply(
          "Không có EA nào đang kết nối TCP."
        );
      }

      return;
    }

    /* ========================================================
       SET SL
    ======================================================== */

    const slMatch =
      normalizedText.match(
        /^\/?sl\s+(\d+(?:[.,]\d+)?)$/i
      );

    if (slMatch) {
      const price =
        Number(
          slMatch[1].replace(
            ",",
            "."
          )
        );

      if (
        !Number.isFinite(
          price
        ) ||
        price <= 0
      ) {
        await ctx.reply(
          "Giá SL không hợp lệ."
        );

        return;
      }

      const signal = {
        symbol:
          "XAUUSD",

        type:
          "SET_SL",

        price,

        createdAt:
          Date.now(),
      };

      const delivered =
        broadcastSignal(
          signal
        );

      if (
        delivered > 0
      ) {
        await ctx.react(
          "👍"
        );
      } else {
        await ctx.reply(
          "Không có EA nào đang kết nối TCP."
        );
      }

      return;
    }

    /* ========================================================
       SET TP
    ======================================================== */

    const tpMatch =
      normalizedText.match(
        /^\/?tp\s+(\d+(?:[.,]\d+)?)$/i
      );

    if (tpMatch) {
      const price =
        Number(
          tpMatch[1].replace(
            ",",
            "."
          )
        );

      if (
        !Number.isFinite(
          price
        ) ||
        price <= 0
      ) {
        await ctx.reply(
          "Giá TP không hợp lệ."
        );

        return;
      }

      const signal = {
        symbol:
          "XAUUSD",

        type:
          "SET_TP",

        price,

        createdAt:
          Date.now(),
      };

      const delivered =
        broadcastSignal(
          signal
        );

      if (
        delivered > 0
      ) {
        await ctx.react(
          "👍"
        );
      } else {
        await ctx.reply(
          "Không có EA nào đang kết nối TCP."
        );
      }

      return;
    }

    /* ========================================================
       NEW ORDER
    ======================================================== */

    const signal =
      parseOrderSignal(
        originalText
      );

    if (!signal) {
      return;
    }

    const delivered =
      broadcastSignal(
        signal
      );

    /* ---------------- INLINE KEYBOARD ---------------- */

    const keyboard = [];

    signal.orders.forEach(
      (order, index) => {
        const rTargets =
          getRTargets(
            signal,
            order,
            5
          );

        const tpPrefix =
          "TP ";

        keyboard.push([
          {
            text:
              `📥 E${index + 1} ${order.entry}`,

            copy_text: {
              text:
                String(
                  order.entry
                ),
            },
          },

          {
            text:
              `🎯 TP ${
                order.tp ??
                "N/A"
              }`,

            copy_text: {
              text:
                tpPrefix +
                String(
                  order.tp ??
                  ""
                ),
            },
          },
        ]);

        /*
         * Nếu SL == Entry thì
         * riskDistance = 0.
         *
         * Tránh crash vì
         * rTargets[0] undefined.
         */

        if (
          rTargets.length >= 5
        ) {
          keyboard.push([
            {
              text:
                `1R ${rTargets[0].price}`,

              copy_text: {
                text:
                  tpPrefix +
                  rTargets[0]
                    .price,
              },
            },

            {
              text:
                `2R ${rTargets[1].price}`,

              copy_text: {
                text:
                  tpPrefix +
                  rTargets[1]
                    .price,
              },
            },
          ]);

          keyboard.push([
            {
              text:
                `3R ${rTargets[2].price}`,

              copy_text: {
                text:
                  tpPrefix +
                  rTargets[2]
                    .price,
              },
            },

            {
              text:
                `5R ${rTargets[4].price}`,

              copy_text: {
                text:
                  tpPrefix +
                  rTargets[4]
                    .price,
              },
            },
          ]);
        }
      }
    );

    keyboard.push([
      {
        text:
          `🛑 SL ${signal.sl}`,

        copy_text: {
          text:
            "SL " +
            String(
              signal.sl
            ),
        },
      },
    ]);

    await ctx.reply(
      formatSignal(
        signal,
        delivered
      ),
      {
        reply_to_message_id:
          ctx.message
            .message_id,

        parse_mode:
          "HTML",

        reply_markup: {
          inline_keyboard:
            keyboard,
        },
      }
    );
  } catch (error) {
    console.error(
      "[TRADE] Handler error:",
      error?.message || error
    );
  }
});

/* ============================================================
   HTTP STATUS API
============================================================ */

app.get(
  "/ping",
  (_req, res) => {
    res.send("pong");
  }
);

app.get(
  "/status",
  (_req, res) => {
    const connectedClients =
      [...clients].map(
        (client) => ({
          authenticated:
            client.authenticated,

          server:
            client.server,

          remoteAddress:
            client.socket
              .remoteAddress,

          connectedAt:
            client.connectedAt,

          lastSeenAt:
            client.lastSeenAt,
        })
      );

    res.json({
      ok: true,

      connectedEA:
        connectedClients.filter(
          (client) =>
            client.authenticated
        ).length,

      clients:
        connectedClients,
    });
  }
);

/* ============================================================
   TCP HEARTBEAT
============================================================ */

setInterval(() => {
  const now = Date.now();

  for (
    const client
    of clients
  ) {
    if (
      client.socket.destroyed
    ) {
      continue;
    }

    /*
     * Không phản hồi > 90s
     * => loại connection.
     */

    if (
      now -
        client.lastSeenAt >
      90_000
    ) {
      client.socket.destroy();

      continue;
    }

    if (
      client.authenticated
    ) {
      sendLine(
        client.socket,
        "PING"
      );
    }
  }
}, 30_000).unref();

/* ============================================================
   START
============================================================ */

async function start() {
  console.log(
    "🚀 Starting combined app..."
  );

  /* ---------------- GramJS ---------------- */

  await userClient.connect();

  console.log(
    "👤 Telegram user client connected"
  );

  /* ---------------- TCP ---------------- */

  tcpServer.listen(
    CONFIG.tcpPort,
    CONFIG.tcpHost,
    () => {
      console.log(
        `🔌 TCP server running at ${CONFIG.tcpHost}:${CONFIG.tcpPort}`
      );
    }
  );

  /* ---------------- HTTP ---------------- */

  httpServer =
    app.listen(
      CONFIG.httpPort,
      "0.0.0.0",
      () => {
        console.log(
          `🌐 Status API running at http://0.0.0.0:${CONFIG.httpPort}`
        );
      }
    );

  /* ---------------- Telegram Bot ---------------- */

  bot.launch().catch((error) => {
    console.error(
      "Telegram bot launch error:",
      error?.message || error
    );

    process.exit(1);
  });

  console.log("🤖 Telegram bot running");
  console.log("✅ Combined app started successfully");
}

/* ============================================================
   SHUTDOWN
============================================================ */

async function shutdown(
  signal
) {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;

  console.log(
    `🛑 Shutting down (${signal})...`
  );

  try {
    /* ---------------- Telegram Bot ---------------- */

    try {
      bot.stop(signal);
    } catch {
      // Ignore if bot was not started
    }

    /* ---------------- TCP CLIENTS ---------------- */

    for (
      const client
      of clients
    ) {
      try {
        client.socket.destroy();
      } catch {
        // ignore
      }
    }

    clients.clear();

    /* ---------------- TCP SERVER ---------------- */

    try {
      tcpServer.close();
    } catch {
      // ignore
    }

    /* ---------------- HTTP SERVER ---------------- */

    try {
      if (httpServer) {
        httpServer.close();
      }
    } catch {
      // ignore
    }

    /* ---------------- GramJS ---------------- */

    try {
      if (
        typeof userClient.disconnect ===
        "function"
      ) {
        await userClient.disconnect();
      }
    } catch (
      error
    ) {
      console.error(
        "GramJS disconnect error:",
        error?.message || error
      );
    }
  } finally {
    process.exit(0);
  }
}

/* ============================================================
   PROCESS EVENTS
============================================================ */

process.once(
  "SIGINT",
  () =>
    shutdown(
      "SIGINT"
    )
);

process.once(
  "SIGTERM",
  () =>
    shutdown(
      "SIGTERM"
    )
);

process.on(
  "unhandledRejection",
  (reason) => {
    console.error(
      "UNHANDLED REJECTION:"
    );

    console.error(
      reason
    );
  }
);

process.on(
  "uncaughtException",
  (error) => {
    console.error(
      "UNCAUGHT EXCEPTION:"
    );

    console.error(
      error
    );

    process.exit(1);
  }
);

/* ============================================================
   RUN
============================================================ */

start().catch(
  (error) => {
    console.error(
      "Startup error:",
      error?.message || error
    );

    process.exit(1);
  }
);
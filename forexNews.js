const https = require("https");
const fs = require("fs");
const path = require("path");

/* ============================================================
   FOREX FACTORY - USD HIGH IMPACT NEWS
============================================================ */

const FOREX_FACTORY_URL =
  "https://nfs.faireconomy.media/ff_calendar_thisweek.json";

function toFiniteNumber(value, fallback) {
  const number = Number(value);

  return Number.isFinite(number)
    ? number
    : fallback;
}

function escapeHtml(value) {
  if (
    value === null ||
    value === undefined
  ) {
    return "";
  }

  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function valueOrDash(value) {
  if (
    value === null ||
    value === undefined ||
    String(value).trim() === ""
  ) {
    return "—";
  }

  return escapeHtml(value);
}

function fetchJson(url, redirectCount = 0) {
  return new Promise(
    (resolve, reject) => {
      const request = https.get(
        url,
        {
          headers: {
            "User-Agent":
              "Mozilla/5.0 ForexNewsTelegramBot/1.0",
            Accept:
              "application/json,text/plain,*/*",
          },
        },
        (response) => {
          const statusCode =
            response.statusCode || 0;

          if (
            statusCode >= 300 &&
            statusCode < 400 &&
            response.headers.location
          ) {
            response.resume();

            if (redirectCount >= 5) {
              reject(
                new Error(
                  "Too many redirects from Forex Factory"
                )
              );

              return;
            }

            const nextUrl =
              new URL(
                response.headers.location,
                url
              ).toString();

            fetchJson(
              nextUrl,
              redirectCount + 1
            )
              .then(resolve)
              .catch(reject);

            return;
          }

          if (
            statusCode < 200 ||
            statusCode >= 300
          ) {
            response.resume();

            reject(
              new Error(
                `Forex Factory HTTP ${statusCode}`
              )
            );

            return;
          }

          response.setEncoding("utf8");

          let raw = "";

          response.on(
            "data",
            (chunk) => {
              raw += chunk;

              if (
                raw.length >
                5 * 1024 * 1024
              ) {
                request.destroy(
                  new Error(
                    "Forex Factory response too large"
                  )
                );
              }
            }
          );

          response.on(
            "end",
            () => {
              try {
                resolve(
                  JSON.parse(raw)
                );
              } catch (error) {
                reject(
                  new Error(
                    `Invalid Forex Factory JSON: ${error.message}`
                  )
                );
              }
            }
          );
        }
      );

      request.setTimeout(
        15_000,
        () => {
          request.destroy(
            new Error(
              "Forex Factory request timeout"
            )
          );
        }
      );

      request.on(
        "error",
        reject
      );
    }
  );
}

function createForexNews(
  bot,
  options = {}
) {
  if (!bot) {
    throw new Error(
      "createForexNews requires Telegraf bot instance"
    );
  }

  const enabled =
    String(
      process.env.FOREX_NEWS_ENABLED ??
        options.enabled ??
        "true"
    ).toLowerCase() !== "false";

  const allowedUserId =
    toFiniteNumber(
      options.allowedUserId,
      null
    );

  const chatId =
    toFiniteNumber(
      process.env.FOREX_NEWS_CHAT_ID ??
        options.chatId,
      allowedUserId
    );

  const timezone =
    process.env.FOREX_NEWS_TIMEZONE ||
    options.timezone ||
    "Asia/Ho_Chi_Minh";

  const reportHour =
    toFiniteNumber(
      process.env.FOREX_NEWS_REPORT_HOUR ??
        options.reportHour,
      7
    );

  const reportMinute =
    toFiniteNumber(
      process.env.FOREX_NEWS_REPORT_MINUTE ??
        options.reportMinute,
      0
    );

  const remindBeforeMinutes =
    toFiniteNumber(
      process.env.FOREX_NEWS_REMIND_MINUTES ??
        options.remindBeforeMinutes,
      30
    );

  // Timer chỉ kiểm tra cache mỗi 5 phút.
  // Request thật tới Forex Factory bị chặn bởi minRefreshAgeMs ở dưới,
  // nên tối đa chỉ request khoảng 1 lần / 65 phút.
  const refreshEveryMs =
    Math.max(
      60_000,
      toFiniteNumber(
        options.refreshEveryMs,
        5 * 60_000
      )
    );

  // Forex Factory Calendar Export chỉ cập nhật 1 lần / giờ.
  // Dùng 65 phút để có buffer, tránh chạm rate limit đúng biên 60 phút.
  const minRefreshAgeMs =
    Math.max(
      60 * 60_000,
      toFiniteNumber(
        options.minRefreshAgeMs,
        65 * 60_000
      )
    );

  // Nếu request thất bại/rate-limit, không retry liên tục khi nhiều người
  // cùng dùng /today hoặc /next.
  const failedRetryCooldownMs =
    Math.max(
      5 * 60_000,
      toFiniteNumber(
        options.failedRetryCooldownMs,
        6 * 60_000
      )
    );

  const checkEveryMs =
    Math.max(
      5_000,
      toFiniteNumber(
        options.checkEveryMs,
        15_000
      )
    );

  const stateFile =
    options.stateFile ||
    path.join(
      __dirname,
      "forexNewsState.json"
    );

  const calendarCacheFile =
    options.calendarCacheFile ||
    path.join(
      __dirname,
      "forexCalendarCache.json"
    );

  let calendarEvents = [];
  let lastRefreshAt = null;
  let lastAttemptAt = null;

  let refreshTimer = null;
  let checkTimer = null;

  let refreshing = false;
  let checking = false;
  let started = false;

  function defaultState() {
    return {
      dailySummaryDate: null,
      reminderGroups: {},
    };
  }

  function loadState() {
    try {
      if (
        !fs.existsSync(
          stateFile
        )
      ) {
        return defaultState();
      }

      const parsed =
        JSON.parse(
          fs.readFileSync(
            stateFile,
            "utf8"
          )
        );

      return {
        ...defaultState(),
        ...parsed,
        reminderGroups: {
          ...(parsed.reminderGroups ||
            {}),
        },
      };
    } catch (error) {
      console.error(
        "[NEWS] Cannot read state:",
        error?.message || error
      );

      return defaultState();
    }
  }

  const state =
    loadState();

  function loadCalendarCache() {
    try {
      if (
        !fs.existsSync(
          calendarCacheFile
        )
      ) {
        return;
      }

      const parsed =
        JSON.parse(
          fs.readFileSync(
            calendarCacheFile,
            "utf8"
          )
        );

      if (
        Array.isArray(
          parsed.events
        )
      ) {
        calendarEvents =
          parsed.events.filter(
            (event) =>
              event &&
              typeof event ===
                "object"
          );
      }

      if (
        parsed.fetchedAt
      ) {
        const fetchedAt =
          new Date(
            parsed.fetchedAt
          );

        if (
          !Number.isNaN(
            fetchedAt.getTime()
          )
        ) {
          lastRefreshAt =
            fetchedAt;
        }
      }

      if (
        parsed.lastAttemptAt
      ) {
        const attemptedAt =
          new Date(
            parsed.lastAttemptAt
          );

        if (
          !Number.isNaN(
            attemptedAt.getTime()
          )
        ) {
          lastAttemptAt =
            attemptedAt;
        }
      }

      if (
        calendarEvents.length >
        0
      ) {
        console.log(
          `[NEWS] Calendar cache loaded: ${calendarEvents.length} events` +
            (
              lastRefreshAt
                ? ` | fetched=${lastRefreshAt.toISOString()}`
                : ""
            )
        );
      }
    } catch (error) {
      console.error(
        "[NEWS] Cannot read calendar cache:",
        error?.message || error
      );
    }
  }

  function saveCalendarCache() {
    try {
      fs.writeFileSync(
        calendarCacheFile,
        JSON.stringify(
          {
            fetchedAt:
              lastRefreshAt
                ? lastRefreshAt.toISOString()
                : null,
            lastAttemptAt:
              lastAttemptAt
                ? lastAttemptAt.toISOString()
                : null,
            events:
              calendarEvents,
          },
          null,
          2
        ),
        "utf8"
      );
    } catch (error) {
      console.error(
        "[NEWS] Cannot save calendar cache:",
        error?.message || error
      );
    }
  }

  loadCalendarCache();

  function saveState() {
    try {
      fs.writeFileSync(
        stateFile,
        JSON.stringify(
          state,
          null,
          2
        ),
        "utf8"
      );
    } catch (error) {
      console.error(
        "[NEWS] Cannot save state:",
        error?.message || error
      );
    }
  }

  function getZonedParts(
    date = new Date()
  ) {
    const formatter =
      new Intl.DateTimeFormat(
        "en-US",
        {
          timeZone: timezone,
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
          hourCycle: "h23",
        }
      );

    const parts =
      formatter.formatToParts(
        date
      );

    const map = {};

    for (const part of parts) {
      if (
        part.type !==
        "literal"
      ) {
        map[part.type] =
          part.value;
      }
    }

    return {
      year: Number(map.year),
      month: Number(map.month),
      day: Number(map.day),
      hour: Number(map.hour),
      minute: Number(map.minute),
      second: Number(map.second),
    };
  }

  function getDateKey(
    date = new Date()
  ) {
    const parts =
      getZonedParts(date);

    return [
      String(parts.year).padStart(
        4,
        "0"
      ),
      String(parts.month).padStart(
        2,
        "0"
      ),
      String(parts.day).padStart(
        2,
        "0"
      ),
    ].join("-");
  }

  function formatDate(
    date
  ) {
    const parts =
      getZonedParts(date);

    return (
      String(parts.day).padStart(
        2,
        "0"
      ) +
      "/" +
      String(parts.month).padStart(
        2,
        "0"
      ) +
      "/" +
      String(parts.year).padStart(
        4,
        "0"
      )
    );
  }

  function formatTime(
    date
  ) {
    const parts =
      getZonedParts(date);

    return (
      String(parts.hour).padStart(
        2,
        "0"
      ) +
      ":" +
      String(parts.minute).padStart(
        2,
        "0"
      )
    );
  }

  function eventDate(
    event
  ) {
    const date =
      new Date(event?.date);

    if (
      Number.isNaN(
        date.getTime()
      )
    ) {
      return null;
    }

    return date;
  }

  function eventTimeMs(
    event
  ) {
    const date =
      eventDate(event);

    return date
      ? date.getTime()
      : NaN;
  }

  async function refreshCalendar() {
    if (
      !enabled ||
      refreshing
    ) {
      return (
        calendarEvents.length >
        0
      );
    }

    const now =
      Date.now();

    // Cache vẫn còn mới -> tuyệt đối không request Forex Factory.
    if (
      lastRefreshAt &&
      calendarEvents.length > 0 &&
      now -
        lastRefreshAt.getTime() <
        minRefreshAgeMs
    ) {
      return true;
    }

    // Vừa thử request nhưng lỗi/rate-limit -> chờ cooldown.
    // Vẫn dùng cache cũ nếu đang có dữ liệu.
    if (
      lastAttemptAt &&
      now -
        lastAttemptAt.getTime() <
        failedRetryCooldownMs
    ) {
      return (
        calendarEvents.length >
        0
      );
    }

    refreshing = true;

    // Lưu thời điểm attempt trước khi request để restart PM2
    // cũng không tạo burst request trong thời gian bị block.
    lastAttemptAt =
      new Date();

    saveCalendarCache();

    try {
      const data =
        await fetchJson(
          FOREX_FACTORY_URL
        );

      if (
        !Array.isArray(data)
      ) {
        throw new Error(
          "Forex Factory did not return an array"
        );
      }

      calendarEvents =
        data.filter(
          (event) =>
            event &&
            typeof event ===
              "object"
        );

      lastRefreshAt =
        new Date();

      saveCalendarCache();

      console.log(
        `[NEWS] Calendar refreshed: ${calendarEvents.length} events` +
          ` | next request after ~${Math.round(
            minRefreshAgeMs /
              60_000
          )}m`
      );

      return true;
    } catch (error) {
      // Không xóa cache cũ nếu request mới thất bại.
      saveCalendarCache();

      console.error(
        "[NEWS] Calendar refresh failed:",
        error?.message || error,
        calendarEvents.length > 0
          ? "| using cached calendar"
          : ""
      );

      return false;
    } finally {
      refreshing = false;
    }
  }

  function getHighImpactUsdEvents() {
    return calendarEvents
      .filter(
        (event) =>
          String(
            event?.country || ""
          ).toUpperCase() ===
            "USD" &&
          String(
            event?.impact || ""
          ).toLowerCase() ===
            "high" &&
          Number.isFinite(
            eventTimeMs(event)
          )
      )
      .sort(
        (a, b) =>
          eventTimeMs(a) -
          eventTimeMs(b)
      );
  }

  function getTodayEvents() {
    const today =
      getDateKey();

    return getHighImpactUsdEvents()
      .filter(
        (event) => {
          const date =
            eventDate(event);

          return (
            date &&
            getDateKey(date) ===
              today
          );
        }
      );
  }

  function getFutureEvents() {
    const now =
      Date.now();

    return getHighImpactUsdEvents()
      .filter(
        (event) =>
          eventTimeMs(event) >
          now
      );
  }

  function groupEventsByTime(
    events
  ) {
    const groups =
      new Map();

    for (
      const event
      of events
    ) {
      const timestamp =
        eventTimeMs(event);

      if (
        !Number.isFinite(
          timestamp
        )
      ) {
        continue;
      }

      if (
        !groups.has(
          timestamp
        )
      ) {
        groups.set(
          timestamp,
          []
        );
      }

      groups
        .get(timestamp)
        .push(event);
    }

    return [
      ...groups.entries(),
    ]
      .map(
        ([
          timestamp,
          groupedEvents,
        ]) => ({
          timestamp:
            Number(timestamp),
          events:
            groupedEvents,
        })
      )
      .sort(
        (a, b) =>
          a.timestamp -
          b.timestamp
      );
  }

  function formatEvent(
    event
  ) {
    let text = "";

    text +=
      `🔴 <b>${escapeHtml(
        event?.title ||
          "Unknown event"
      )}</b>\n`;

    text +=
      `Forecast: <b>${valueOrDash(
        event?.forecast
      )}</b>`;

    text +=
      ` | Previous: <b>${valueOrDash(
        event?.previous
      )}</b>`;

    return text;
  }

  function buildDailyMessage(
    events
  ) {
    const now =
      new Date();

    if (
      events.length === 0
    ) {
      return (
        `📅 <b>USD HIGH IMPACT — ${formatDate(
          now
        )}</b>\n\n` +
        "✅ Hôm nay không có tin USD High Impact trên Forex Factory."
      );
    }

    const groups =
      groupEventsByTime(
        events
      );

    let text = "";

    text +=
      `📅 <b>USD HIGH IMPACT — ${formatDate(
        now
      )}</b>\n\n`;

    text +=
      `Có <b>${events.length}</b> tin High Impact`;

    text +=
      ` trong <b>${groups.length}</b> khung giờ.\n`;

    for (
      const group
      of groups
    ) {
      const date =
        new Date(
          group.timestamp
        );

      text +=
        "\n━━━━━━━━━━━━━━\n";

      text +=
        `⏰ <b>${formatTime(
          date
        )}</b> 🇻🇳\n\n`;

      for (
        const event
        of group.events
      ) {
        text +=
          formatEvent(event) +
          "\n\n";
      }
    }

    text +=
      "Nguồn: Forex Factory";

    return text.trim();
  }

  function buildReminderMessage(
    group
  ) {
    const now =
      Date.now();

    const diffMinutes =
      Math.max(
        1,
        Math.ceil(
          (
            group.timestamp -
            now
          ) /
            60_000
        )
      );

    const displayMinutes =
      diffMinutes >=
      remindBeforeMinutes - 1
        ? remindBeforeMinutes
        : diffMinutes;

    const date =
      new Date(
        group.timestamp
      );

    let text = "";

    text +=
      `🚨 <b>USD HIGH IMPACT — CÒN ${displayMinutes} PHÚT</b>\n\n`;

    text +=
      `⏰ Ra tin: <b>${formatTime(
        date
      )}</b> 🇻🇳\n`;

    text +=
      `📅 ${formatDate(
        date
      )}\n\n`;

    for (
      const event
      of group.events
    ) {
      text +=
        formatEvent(event) +
        "\n\n";
    }

    text +=
      "⚠️ <b>High Impact USD</b>\n";

    text +=
      "Nguồn: Forex Factory";

    return text.trim();
  }

  function buildNextMessage(
    group
  ) {
    const date =
      new Date(
        group.timestamp
      );

    const diffMinutes =
      Math.max(
        1,
        Math.ceil(
          (
            group.timestamp -
            Date.now()
          ) /
            60_000
        )
      );

    let text = "";

    text +=
      "⏭ <b>USD HIGH IMPACT TIẾP THEO</b>\n\n";

    text +=
      `📅 ${formatDate(
        date
      )}\n`;

    text +=
      `⏰ <b>${formatTime(
        date
      )}</b> 🇻🇳\n`;

    if (
      diffMinutes < 60
    ) {
      text +=
        `⏳ Còn khoảng <b>${diffMinutes} phút</b>\n`;
    } else {
      const hours =
        diffMinutes / 60;

      text +=
        `⏳ Còn khoảng <b>${hours.toFixed(
          1
        )} giờ</b>\n`;
    }

    text += "\n";

    for (
      const event
      of group.events
    ) {
      text +=
        formatEvent(event) +
        "\n\n";
    }

    text +=
      "Nguồn: Forex Factory";

    return text.trim();
  }

  async function sendHtml(
    targetChatId,
    text
  ) {
    if (
      targetChatId ===
        null ||
      targetChatId ===
        undefined
    ) {
      console.error(
        "[NEWS] Missing FOREX_NEWS_CHAT_ID"
      );

      return false;
    }

    try {
      await bot.telegram.sendMessage(
        targetChatId,
        text,
        {
          parse_mode:
            "HTML",
          disable_web_page_preview:
            true,
        }
      );

      return true;
    } catch (error) {
      console.error(
        "[NEWS] Telegram send failed:",
        error?.response
          ?.description ||
          error?.message ||
          error
      );

      return false;
    }
  }

  async function sendToday(
    targetChatId
  ) {
    await refreshCalendar();

    return sendHtml(
      targetChatId,
      buildDailyMessage(
        getTodayEvents()
      )
    );
  }

  async function sendNext(
    targetChatId
  ) {
    await refreshCalendar();

    const futureEvents =
      getFutureEvents();

    if (
      futureEvents.length === 0
    ) {
      return sendHtml(
        targetChatId,
        "✅ Hiện không còn tin USD High Impact nào trong dữ liệu tuần này."
      );
    }

    const timestamp =
      eventTimeMs(
        futureEvents[0]
      );

    const group = {
      timestamp,
      events:
        futureEvents.filter(
          (event) =>
            eventTimeMs(
              event
            ) === timestamp
        ),
    };

    return sendHtml(
      targetChatId,
      buildNextMessage(
        group
      )
    );
  }

  function isAllowedCommand(
    ctx
  ) {
    if (
      !ctx?.from ||
      !ctx?.chat
    ) {
      return false;
    }

    if (
      ctx.chat.type !==
      "private"
    ) {
      return false;
    }

    if (
      allowedUserId !==
        null &&
      ctx.from.id !==
        allowedUserId
    ) {
      return false;
    }

    return true;
  }

  /*
   * Đăng ký command ngay khi module được tạo.
   * Entry point phải create module này trước bot.on("text")
   * để /today và /next không bị handler trade nuốt mất.
   */

  bot.command(
    "today",
    async (ctx) => {
      if (
        !isAllowedCommand(
          ctx
        )
      ) {
        return;
      }

      await sendToday(
        ctx.chat.id
      );
    }
  );

  bot.command(
    "news",
    async (ctx) => {
      if (
        !isAllowedCommand(
          ctx
        )
      ) {
        return;
      }

      await sendToday(
        ctx.chat.id
      );
    }
  );

  bot.command(
    "next",
    async (ctx) => {
      if (
        !isAllowedCommand(
          ctx
        )
      ) {
        return;
      }

      await sendNext(
        ctx.chat.id
      );
    }
  );

  async function checkDailyReport() {
    if (
      !enabled ||
      chatId === null
    ) {
      return;
    }

    const now =
      new Date();

    const parts =
      getZonedParts(now);

    const today =
      getDateKey(now);

    const afterReportTime =
      parts.hour >
        reportHour ||
      (
        parts.hour ===
          reportHour &&
        parts.minute >=
          reportMinute
      );

    if (
      !afterReportTime ||
      state.dailySummaryDate ===
        today
    ) {
      return;
    }

    const success =
      await sendHtml(
        chatId,
        buildDailyMessage(
          getTodayEvents()
        )
      );

    if (success) {
      state.dailySummaryDate =
        today;

      saveState();

      console.log(
        `[NEWS] Daily report sent: ${today}`
      );
    }
  }

  async function checkReminders() {
    if (
      !enabled ||
      chatId === null
    ) {
      return;
    }

    const now =
      Date.now();

    const groups =
      groupEventsByTime(
        getFutureEvents()
      );

    for (
      const group
      of groups
    ) {
      const diffMs =
        group.timestamp -
        now;

      const diffMinutes =
        diffMs / 60_000;

      if (
        diffMinutes <= 0 ||
        diffMinutes >
          remindBeforeMinutes
      ) {
        continue;
      }

      const key =
        String(
          group.timestamp
        );

      if (
        state.reminderGroups[
          key
        ]
      ) {
        continue;
      }

      const success =
        await sendHtml(
          chatId,
          buildReminderMessage(
            group
          )
        );

      if (success) {
        state.reminderGroups[
          key
        ] = {
          sentAt:
            new Date().toISOString(),
          eventTime:
            new Date(
              group.timestamp
            ).toISOString(),
        };

        saveState();

        console.log(
          `[NEWS] Reminder sent: ${formatDate(
            new Date(
              group.timestamp
            )
          )} ${formatTime(
            new Date(
              group.timestamp
            )
          )}`
        );
      }
    }
  }

  function cleanOldState() {
    const now =
      Date.now();

    const maxAge =
      3 *
      24 *
      60 *
      60 *
      1000;

    let changed =
      false;

    for (
      const key
      of Object.keys(
        state.reminderGroups
      )
    ) {
      const timestamp =
        Number(key);

      if (
        Number.isFinite(
          timestamp
        ) &&
        now - timestamp >
          maxAge
      ) {
        delete state
          .reminderGroups[
            key
          ];

        changed =
          true;
      }
    }

    if (changed) {
      saveState();
    }
  }

  async function tick() {
    if (
      !enabled ||
      checking
    ) {
      return;
    }

    checking = true;

    try {
      await checkDailyReport();

      await checkReminders();

      cleanOldState();
    } catch (error) {
      console.error(
        "[NEWS] Check failed:",
        error?.message || error
      );
    } finally {
      checking = false;
    }
  }

  async function start() {
    if (
      started ||
      !enabled
    ) {
      if (!enabled) {
        console.log(
          "[NEWS] Forex news disabled"
        );
      }

      return;
    }

    started = true;

    console.log(
      `[NEWS] Starting | timezone=${timezone}` +
        ` | daily=${String(
          reportHour
        ).padStart(
          2,
          "0"
        )}:${String(
          reportMinute
        ).padStart(
          2,
          "0"
        )}` +
        ` | reminder=${remindBeforeMinutes}m` +
        ` | calendar-cache=${Math.round(
          minRefreshAgeMs /
            60_000
        )}m`
    );

    await refreshCalendar();

    await tick();

    refreshTimer =
      setInterval(
        () => {
          refreshCalendar()
            .catch(
              (error) => {
                console.error(
                  "[NEWS] Refresh timer error:",
                  error?.message ||
                    error
                );
              }
            );
        },
        refreshEveryMs
      );

    checkTimer =
      setInterval(
        () => {
          tick().catch(
            (error) => {
              console.error(
                "[NEWS] Tick timer error:",
                error?.message ||
                  error
              );
            }
          );
        },
        checkEveryMs
      );

    if (
      typeof refreshTimer.unref ===
      "function"
    ) {
      refreshTimer.unref();
    }

    if (
      typeof checkTimer.unref ===
      "function"
    ) {
      checkTimer.unref();
    }
  }

  function stop() {
    if (
      refreshTimer
    ) {
      clearInterval(
        refreshTimer
      );

      refreshTimer = null;
    }

    if (
      checkTimer
    ) {
      clearInterval(
        checkTimer
      );

      checkTimer = null;
    }

    started = false;
  }

  return {
    start,
    stop,
    refreshCalendar,
    sendToday,
    sendNext,
    getTodayEvents,
    getFutureEvents,
    getLastRefreshAt: () =>
      lastRefreshAt,
    getCalendarCacheFile: () =>
      calendarCacheFile,
  };
}

module.exports = {
  createForexNews,
};

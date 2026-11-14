// The /admin page. The login token lives in this variable only; leaving the
// page asks the server to end that login. Every text from the server goes in
// through textContent, never as markup.
"use strict";

const TEXTS = {
  en: {
    title: "Apertonodo",
    signInTitle: "Sign in to Apertonodo",
    username: "Username",
    password: "Password",
    signIn: "Sign in",
    signOut: "Sign out",
    state: "Server",
    people: "People",
    addPerson: "Add a person",
    administrator: "Administrator",
    add: "Add",
    database: "Database",
    ok: "OK",
    peopleCount: "People",
    activeCount: "Active",
    adminCount: "Administrators",
    deviceCount: "Signed-in devices",
    freeSpace: "Free space",
    totalSpace: "Disk size",
    cacheSpace: "Music cache",
    unknown: "Unknown",
    off: "Disabled",
    devices: "Devices",
    noDevices: "No signed-in devices",
    lastUsed: "last used",
    addHint: "No password here: the person gets a sign-in code and makes up the password in the app",
    giveCode: "New sign-in code",
    inviteFor: "Sign-in code for",
    inviteHow: "In the app: server address, the name, this code, then a password of their own. The code works once, until",
    inviteReset: "Their old password and all their devices are signed out.",
    disable: "Disable",
    enable: "Enable",
    makeAdmin: "Make administrator",
    removeAdmin: "Remove administrator rights",
    revoke: "Sign out this device",
    done: "Done",
    wrongLogin: "Wrong username or password",
    tooMany: "Too many attempts. Try again later",
    notAdmin: "This person is not an administrator",
    unavailable: "The server is not available. Try again",
    invalid: "Check the username",
    exists: "This username is taken",
    lastAdmin: "This is the last administrator",
    notFound: "Not found. The list is refreshed",
    signedOut: "You are signed out. Sign in again",
    signOutFailed: "The server did not confirm the sign-out. Check the device list later",
  },
  ru: {
    title: "Apertonodo",
    signInTitle: "Вход в Apertonodo",
    username: "Имя",
    password: "Пароль",
    signIn: "Войти",
    signOut: "Выйти",
    state: "Сервер",
    people: "Люди",
    addPerson: "Добавить человека",
    administrator: "Администратор",
    add: "Добавить",
    database: "База",
    ok: "В порядке",
    peopleCount: "Людей",
    activeCount: "Включено",
    adminCount: "Администраторов",
    deviceCount: "Устройств со входом",
    freeSpace: "Свободно",
    totalSpace: "Размер диска",
    cacheSpace: "Кэш музыки",
    unknown: "Неизвестно",
    off: "Выключен",
    devices: "Устройства",
    noDevices: "Нет устройств со входом",
    lastUsed: "был",
    addHint: "Пароль здесь не нужен: человек получит код входа и придумает пароль сам в приложении",
    giveCode: "Новый код входа",
    inviteFor: "Код входа для",
    inviteHow: "В приложении: адрес сервера, имя, этот код и свой пароль. Код действует один раз, до",
    inviteReset: "Прежний пароль больше не действует, все его устройства вышли.",
    disable: "Выключить",
    enable: "Включить",
    makeAdmin: "Сделать администратором",
    removeAdmin: "Снять права администратора",
    revoke: "Выйти на этом устройстве",
    done: "Готово",
    wrongLogin: "Неверное имя или пароль",
    tooMany: "Слишком много попыток. Попробуйте позже",
    notAdmin: "Этот человек не администратор",
    unavailable: "Сервер недоступен. Попробуйте ещё раз",
    invalid: "Проверьте имя",
    exists: "Это имя занято",
    lastAdmin: "Это последний администратор",
    notFound: "Не найдено. Список обновлён",
    signedOut: "Вход закончился. Войдите снова",
    signOutFailed: "Сервер не подтвердил выход. Проверьте список устройств позже",
  },
};

const lang = (navigator.language || "en").toLowerCase().startsWith("ru") ? "ru" : "en";
const t = (key) => TEXTS[lang][key] || TEXTS.en[key] || key;
const $ = (id) => document.getElementById(id);

let token = null;
let busy = false;
const open = new Set();

// One action at a time: a second press while a request is on its way is dropped.
async function once(work) {
  if (busy) return undefined;
  busy = true;
  try {
    return await work();
  } finally {
    busy = false;
  }
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function say(id, key, ok) {
  const node = $(id);
  node.textContent = key ? t(key) : "";
  node.classList.toggle("ok", Boolean(ok));
}

async function call(method, path, body, keepalive) {
  const headers = {};
  if (token) headers.Authorization = "Bearer " + token;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
      credentials: "omit",
      keepalive: Boolean(keepalive),
    });
  } catch (error) {
    return { status: 0, data: {} };
  }
  let data = {};
  try {
    data = await response.json();
  } catch (error) {
    data = {};
  }
  return { status: response.status, data: data && typeof data === "object" ? data : {} };
}

const ERRORS = { 0: "unavailable", 404: "notFound", 422: "invalid", 429: "tooMany", 503: "unavailable" };

// True when the reply is a success; otherwise shows why and, when the login
// is gone, returns to the sign-in form.
function fine(reply) {
  if (reply.status >= 200 && reply.status < 300) return true;
  if (reply.status === 401 || reply.status === 403) {
    leave("signedOut");
    return false;
  }
  if (reply.status === 409) {
    say("note", reply.data.status === "last_admin" ? "lastAdmin" : "exists");
    return false;
  }
  say("note", ERRORS[reply.status] || "unavailable");
  return false;
}

function leave(noteKey) {
  token = null;
  open.clear();
  $("add-form").reset();
  say("note", "");
  $("panel").hidden = true;
  $("login").hidden = false;
  $("people").replaceChildren();
  $("state").replaceChildren();
  $("login-password").value = "";
  say("login-note", noteKey || "");
}

function bytes(value) {
  if (typeof value !== "number") return t("unknown");
  const gb = value / 1024 / 1024 / 1024;
  return gb.toFixed(gb < 10 ? 1 : 0) + " GB";
}

function fact(label, value) {
  const box = el("div");
  box.append(el("dt", "", label), el("dd", "", String(value)));
  return box;
}

async function loadState() {
  const reply = await call("GET", "/v1/admin/state");
  if (!fine(reply)) return false;
  const d = reply.data;
  const users = d.users || {};
  const facts = [
    fact(t("database"), d.database === "ok" ? t("ok") : t("unknown")),
    fact(t("peopleCount"), users.total ?? t("unknown")),
    fact(t("activeCount"), users.active ?? t("unknown")),
    fact(t("adminCount"), users.admins ?? t("unknown")),
    fact(t("deviceCount"), d.devices ?? t("unknown")),
  ];
  if (d.storage) {
    facts.push(
      fact(t("freeSpace"), bytes(d.storage.free_bytes)),
      fact(t("totalSpace"), bytes(d.storage.total_bytes)),
      fact(t("cacheSpace"), bytes(d.storage.cache_bytes)),
    );
  }
  $("state").replaceChildren(...facts);
  return true;
}

function button(label, className, onClick, who) {
  const node = el("button", className, label);
  node.type = "button";
  if (who) node.setAttribute("aria-label", label + ": " + who);
  node.addEventListener("click", () => once(onClick));
  return node;
}

async function act(path, body) {
  say("note", "");
  const reply = await call("POST", path, body);
  const good = fine(reply);
  if (good) say("note", "done", true);
  if (token) await refresh();
  return good ? reply : null;
}

// FT-856: the code is shown once, here; the server keeps only its digest.
function showInvite(who, invite, reset) {
  const box = $("invite");
  const until = new Date(invite.expires_at).toLocaleString(lang);
  box.replaceChildren(
    el("p", "", t("inviteFor") + " " + who + ":"),
    el("p", "invite-code", String(invite.code)),
    el("p", "meta", t("inviteHow") + " " + until + "."),
  );
  if (reset) box.append(el("p", "meta", t("inviteReset")));
  box.hidden = false;
}

async function showDevices(person, list) {
  const mine = token;
  const reply = await call("GET", "/v1/admin/users/" + person.id + "/devices");
  if (token !== mine || !fine(reply)) return;
  open.add(person.id);
  const devices = Array.isArray(reply.data.devices) ? reply.data.devices : [];
  if (!devices.length) {
    list.replaceChildren(el("li", "meta", t("noDevices")));
    return;
  }
  list.replaceChildren(
    ...devices.map((device) => {
      const row = el("li");
      row.append(
        el("span", "device-name", String(device.device_name || "")),
        el("span", "meta", t("lastUsed") + " " + String(device.last_used_date || "")),
        button(
          t("revoke"),
          "danger",
          () => act("/v1/admin/users/" + person.id + "/devices/" + device.id + "/revoke"),
          String(device.device_name || ""),
        ),
      );
      return row;
    }),
  );
}

function personRow(person) {
  const row = el("div", person.is_active ? "person" : "person off");
  const head = el("div", "person-head");
  head.append(el("span", "person-name", String(person.username)));
  if (person.is_admin) head.append(el("span", "badge", t("administrator")));
  if (!person.is_active) head.append(el("span", "meta", t("off")));
  head.append(el("span", "meta", t("devices") + ": " + String(person.devices ?? 0)));

  const list = el("ul", "devices");
  const who = String(person.username);
  const base = "/v1/admin/users/" + person.id;
  const actions = el("div", "actions");
  actions.append(
    button(t("giveCode"), "", async () => {
      const reply = await act(base + "/invite");
      if (reply) showInvite(who, reply.data.invite, true);
    }, who),
    button(
      person.is_active ? t("disable") : t("enable"),
      person.is_active ? "danger" : "",
      () => act(base + "/active", { active: !person.is_active }),
      who,
    ),
    button(
      person.is_admin ? t("removeAdmin") : t("makeAdmin"),
      person.is_admin ? "danger" : "",
      () => act(base + "/admin", { admin: !person.is_admin }),
      who,
    ),
    button(t("devices"), "", () => showDevices(person, list), who),
  );
  row.append(head, actions, list);
  if (open.has(person.id)) showDevices(person, list);
  return row;
}

async function refresh() {
  const mine = token;
  if (!(await loadState()) || token !== mine) return;
  const reply = await call("GET", "/v1/admin/users");
  if (token !== mine || !fine(reply)) return;
  const users = Array.isArray(reply.data.users) ? reply.data.users : [];
  $("people").replaceChildren(...users.map(personRow));
}

async function signIn() {
  say("login-note", "");
  const reply = await call("POST", "/v1/auth/login", {
    username: $("login-name").value,
    password: $("login-password").value,
    device_name: "Admin page",
  });
  $("login-password").value = "";
  if (reply.status !== 200 || typeof reply.data.token !== "string") {
    const key = reply.status === 429 ? "tooMany" : reply.status === 401 || reply.status === 400 ? "wrongLogin" : "unavailable";
    return say("login-note", key);
  }
  token = reply.data.token;
  const state = await call("GET", "/v1/admin/state");
  if (state.status === 403) {
    // Not an administrator: do not leave a signed-in device behind.
    await call("POST", "/v1/auth/logout");
    return leave("notAdmin");
  }
  if (state.status !== 200) {
    await call("POST", "/v1/auth/logout");
    return leave("unavailable");
  }
  $("login").hidden = true;
  $("panel").hidden = false;
  say("note", "");
  $("sign-out").focus();
  return refresh();
}

$("login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  once(signIn);
});

$("sign-out").addEventListener("click", () =>
  once(async () => {
    const reply = await call("POST", "/v1/auth/logout");
    leave(reply.status >= 200 && reply.status < 300 ? "" : "signOutFailed");
  }),
);

// Closing or reloading the tab ends the login on the server too.
window.addEventListener("pagehide", () => {
  if (token) call("POST", "/v1/auth/logout", undefined, true);
  token = null;
});

async function addPerson() {
  const reply = await act("/v1/admin/users", {
    username: $("add-name").value,
    is_admin: $("add-admin").checked,
  });
  if (reply) {
    showInvite(String(reply.data.user.username), reply.data.invite, false);
    $("add-name").value = "";
    $("add-admin").checked = false;
  }
}

$("add-form").addEventListener("submit", (event) => {
  event.preventDefault();
  once(addPerson);
});

document.documentElement.lang = lang;
for (const node of document.querySelectorAll("[data-t]")) node.textContent = t(node.dataset.t);

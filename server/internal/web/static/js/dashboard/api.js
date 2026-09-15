export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function sessionToken() {
  return sessionStorage.getItem("token");
}

export function signOutLocally() {
  sessionStorage.removeItem("token");
  sessionStorage.removeItem("cnx_sync_key");
  location.href = "/login";
}

async function request(method, path, body) {
  const headers = { Authorization: "Bearer " + sessionToken() };
  const init = { method, headers };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }

  let response;
  try {
    response = await fetch(path, init);
  } catch {
    throw new ApiError(0, "Cannot reach the sync server");
  }

  let json = {};
  try {
    json = await response.json();
  } catch {
  }

  if (response.status === 401) {
    signOutLocally();
  }
  if (!response.ok) {
    throw new ApiError(response.status, json.error || `Request failed (${response.status})`);
  }
  return json;
}

export const api = {
  get: (path) => request("GET", path),
  post: (path, body = {}) => request("POST", path, body),
  patch: (path, body = {}) => request("PATCH", path, body),
  delete: (path) => request("DELETE", path),
};

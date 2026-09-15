-- rate-limit.lua
-- Email-based rate limiting for OpenResty sidecar
-- 1 request per 3 seconds per hashed email (20 req/min)
-- Uses lua-resty-limit-traffic shared dict

local limit_req = require "resty.limit.req"

local M = {}

-- Shared dict name and rate config
local DICT_NAME = "email_rate_limit"
local RATE = 20        -- 20 requests per 60 seconds = 1 every 3s
local BURST = 0        -- no burst

function M.enforce()
    -- Only throttle POST requests (login attempts)
    if ngx.req.get_method() ~= "POST" then
        return
    end

    -- Read and parse request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then
        -- Try body file for large bodies
        local body_file = ngx.req.get_body_file()
        if body_file then
            local f = io.open(body_file, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    if not body or body == "" then
        return
    end

    -- Try to extract email/loginName from JSON body
    local cjson = require "cjson"
    local success, data = pcall(cjson.decode, body)
    if not success or not data then
        return
    end

    -- Zitadel uses 'loginName' for email in login requests
    -- Forgejo uses 'user_name' or 'email'
    local email = data.loginName or data.email or data.username or data.user_name
    if not email or email == "" then
        return
    end

    -- Normalize: trim whitespace, lowercase
    email = string.gsub(email, "^%s*(.-)%s*$", "%1")
    email = string.lower(email)

    -- Use the email directly as the key (shared dict handles hashing internally)
    local key = "email:" .. email

    -- Create rate limiter
    local lim, err = limit_req.new(DICT_NAME, RATE, BURST)
    if not lim then
        ngx.log(ngx.ERR, "failed to create rate limiter: ", err)
        return
    end

    -- Check rate limit
    local delay, err2 = lim:incoming(key, true)
    if not delay then
        if err2 == "rejected" then
            -- Rate limit exceeded
            ngx.header["Retry-After"] = "3"
            ngx.header["Content-Type"] = "application/json"
            ngx.status = 429
            ngx.say(cjson.encode({ error = "Too many requests", retry_after = 3 }))
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        else
            ngx.log(ngx.ERR, "rate limiter error: ", err2)
            return
        end
    end

    -- If we got a delay, sleep to enforce it (leaky bucket)
    if delay > 0 then
        ngx.sleep(delay)
    end
end

return M

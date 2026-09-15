FROM openresty/openresty:alpine

# lua-resty-limit-traffic is a pure-Lua library with no C deps.
# Vendor it directly from GitHub instead of fighting luarocks in Alpine.
RUN apk add --no-cache git && \
    cd /tmp && git clone --depth 1 https://github.com/openresty/lua-resty-limit-traffic.git && \
    cp -r lua-resty-limit-traffic/lib/resty/limit /usr/local/openresty/lualib/resty/ && \
    rm -rf /tmp/lua-resty-limit-traffic && \
    apk del git

# Copy the rate-limiting config
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY rate-limit.lua /usr/local/openresty/lualib/rate-limit.lua

EXPOSE 8080

CMD ["openresty", "-g", "daemon off;"]

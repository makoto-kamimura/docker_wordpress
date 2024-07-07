# Docker_wordpress
Wordpress環境簡易デプロイツール  
当ツールは、Dockerを用いて簡易的にWordPress環境を立ち上げるスクリプトツールです。  

# DEMO
 ※デモ画像等後程記載を予定

# Requirement
## Environment
* Wordpress:latest
* mysql:5.7
* nginx:latest
* certbot/certbot

## Device
* Device: MacBook Air (2020)
* Operating System: macOS Sonoma 14.5
* Browser: Google chrome Version 126.0.6478.127

# Installation
Local deploy
1. Git clone https://github.com/makoto-kamimura/Docker_wordpress.git
2. "docker_wordpress/docker-compose.yml"の存在するディレクトリまで移動
3. "docker-compose down -v && docker-compose build && docker-compose up -d"をターミナルにて実行
4. "localhost:8000"をブラウザにて入力/実行

# SSL
## external
1. nginx_data/conf.d/default.confファイルを編集
    1. example.com を取得したドメイン名に変更
2. Certbotで証明書を取得
    1. docker-compose run certbot certonly --webroot --webroot-path=/usr/share/nginx/html --email your-email@example.com --agree-tos --no-eff-email -d example.com
3. 証明書の反映
    1. docker-compose down && docker-compose up -d
## internal
1. プライベートキーの発行
    1. openssl genpkey -algorithm RSA -out ./nginx_data/certs/privkey.pem -pkeyopt rsa_keygen_bits:2048
2. 証明書署名要求 (CSR) の作成
    1. openssl req -new -key ./nginx_data/certs/privkey.pem -out ./nginx_data/certs/cert.csr
    2. Common Name (e.g. server FQDN or YOUR name)には、localhostと入力
3. 自己署名証明書の作成
    1. openssl x509 -req -days 365 -in ./nginx_data/certs/cert.csr -signkey ./nginx_data/certs/privkey.pem -out ./nginx_data/certs/fullchain.pem
4. nginx_data/conf.d/default.confファイルの置換
    1. mv nginx_data/conf.d/default.conf nginx_data/conf.d/default_public.conf
    2. mv nginx_data/conf.d/default_local.conf nginx_data/conf.d/default.conf
5. 証明書の反映
    1. docker-compose down && docker-compose up -d

# Note

# License
This system is MIT licensed.
# Docker_wordpress
Wordpress環境簡易デプロイツール  
当ツールは、Dockerを用いて簡易的にWordPress環境を立ち上げるスクリプトツールです。  

# DEMO
 * デモ画像等後程記載を予定

# Requirement
## Environment
* Wordpress:latest
* mysql:5.7
* nginx:latest
* certbot/certbot:latest

## Device
* Device: MacBook Air (2020)
* Operating System: macOS Sonoma 14.5
* Browser: Google chrome Version 126.0.6478.127

# Installation
## Deploy
1. git clone https://github.com/makoto-kamimura/docker_wordpress.git
2. cd ./docker_wordpress/
3. sudo docker-compose down -v && sudo docker-compose build && sudo docker-compose up -d
4. "localhost:8000" をブラウザにて入力/実行
5. [Wordpressにおける初期設定の後、Note内の各種セキュリティの強化を実施](#note)

# SSL
## External
1. ドメイン自動更新の設定
    1. sudo vi docker-compose.yml
    2. example.com を別途取得したドメイン名に変更
        1. :%s/example\.com/makoto-kamimura.com/g
        2. esc
        3. :wq
    3. sudo docker-compose down certbot && sudo docker-compose up -d certbot

2. 証明書発行用のディレクトリ/ファイルを作成
    1. sudo sh -c 'echo "<!DOCTYPE html><html><head><title>Welcome to my site</title></head><body><h1>Hello, World!</h1></body></html>" > ./nginx_data/html/index.html'
    2. sudo chmod -R 755 ./nginx_data/html
    3. sudo cp ./nginx_conf/conf.d/default.conf ./nginx_data/conf.d/default.conf
    4. sudo vi ./nginx_data/conf.d/default.conf
        1. example.com を取得したドメイン名に変更
            1. :%s/localhost/makoto-kamimura.com/g
            2. esc
            3. :wq
    5. sudo docker-compose down nginx && sudo docker-compose up -d nginx
        1. もしくは下記
            1. sudo docker-compose exec nginx nginx -s reload

3. Certbotで証明書を取得
    1. sudo docker exec -it docker_wordpress_certbot_1 sh
    2. certbot certonly --webroot --webroot-path=/usr/share/nginx/html -d makoto-kamimura.com
        ```
        Saving debug log to /var/log/letsencrypt/letsencrypt.log
        Enter email address (used for urgent renewal and security notices)
        (Enter 'c' to cancel): m.kamimura.apple@gmail.com

        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        Please read the Terms of Service at
        https://letsencrypt.org/documents/LE-SA-v1.4-April-3-2024.pdf. You must agree in
        order to register with the ACME server. Do you agree?
        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        (Y)es/(N)o: Y

        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        Would you be willing, once your first certificate is successfully issued, to
        share your email address with the Electronic Frontier Foundation, a founding
        partner of the Let's Encrypt project and the non-profit organization that
        develops Certbot? We'd like to send you email about our work encrypting the web,
        EFF news, campaigns, and ways to support digital freedom.
        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        (Y)es/(N)o: N
        Account registered.
        Requesting a certificate for makoto-kamimura.com

        Successfully received certificate.
        Certificate is saved at: /etc/letsencrypt/live/makoto-kamimura.com/fullchain.pem
        Key is saved at:         /etc/letsencrypt/live/makoto-kamimura.com/privkey.pem
        This certificate expires on 2024-10-11.
        These files will be updated when the certificate renews.

        NEXT STEPS:
        - The certificate will need to be renewed before it expires. Certbot can automatically renew the certificate in the background, but you may need to take steps to enable that functionality. See https://certbot.org/renewal-setup for instructions.

        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        If you like Certbot, please consider supporting our work by:
        * Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
        * Donating to EFF:                    https://eff.org/donate-le
        - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        ```
    3. exit

4. default.confファイルを編集
    1. sudo cp ./nginx_conf/conf.d/default.conf.public ./nginx_data/conf.d/default.conf
    2. sudo vi ./nginx_data/conf.d/default.conf
        1. example.com を取得したドメイン名に変更
            1. :%s/example\.com/makoto-kamimura.com/g
            2. esc
            3. :wq

5. 証明書利用の反映
    1. sudo docker-compose down nginx && sudo docker-compose up -d nginx
        1. もしくは下記
            1. sudo docker-compose exec nginx nginx -s reload

## Internal
1. プライベートキーの発行
    1. openssl genpkey -algorithm RSA -out ./nginx_data/certs/privkey.pem -pkeyopt rsa_keygen_bits:2048
2. 証明書署名要求 (CSR) の作成
    1. openssl req -new -key ./nginx_data/certs/privkey.pem -out ./nginx_data/certs/cert.csr
        1. Common Name (e.g. server FQDN or YOUR name)には、localhostと入力
3. 自己署名証明書の作成
    1. openssl x509 -req -days 365 -in ./nginx_data/certs/cert.csr -signkey ./nginx_data/certs/privkey.pem -out ./nginx_data/certs/fullchain.pem
4. nginx_data/conf.d/default.confファイルの置換
    1. cp ./nginx_conf/conf.d/default.conf.local ./nginx_data/conf.d/default.conf
5. 証明書の反映
    1. docker-compose down && docker-compose up -d

# Note
## カスタムコード
<!-- * WPCode
    * https://wpcode.com/ -->

## メンテナンスモード
a. "functions.php" を編集
```
function maintenance_mode() {
    if (!current_user_can('edit_themes') || !is_user_logged_in()) {
        wp_die('当サイトはメンテナンス中です。');
    }
}
add_action('get_header', 'maintenance_mode');
```
b. "LightStart – Maintenance Mode, Coming Soon and Landing Page Builder" プラグインの利用
* https://ja.wordpress.org/plugins/wp-maintenance-mode/

## sequrity
### 管理画面URLの変更 (設定したURLが管理画面URLになるので失念に注意)
a. ".htaccess" を編集
```
<Files wp-login.php>
order deny,allow
deny from all
allow from xx.xx.xx.xx
</Files>
```

b. "WPS Hide Login" プラグインの利用
* https://wordpress.org/plugins/wps-hide-login/

### 基本認証の追加 (認証設定したページは検索エンジンにて検索されなくなるので注意)
1. ".htpasswd" を作成
    1. ユーザー名とパスワードの生成 ※
        * https://www.luft.co.jp/cgi/htpasswd.php#google_vignette
    2. ファイルの配置
        * /home/username/.htpasswd ※
2. ".htaccess" を作成
    1. "wp-admin" ディレクトリにファイルを配置
```
AuthName "Restricted Area"
AuthType Basic
AuthUserFile /path/to/.htpasswd # "1.2."のディレクトリを記述
require valid-user
```

### ログイン試行回数の制限
a. "Wordfence Security" プラグインの利用
    * https://www.wordfence.com/
        * 自動更新有効化を推奨

## Analytics
a. サーバーログ解析
    a. リバースプロキシのログ
        i. tail -f log_data/nginx_logs/access.log
        ii. tail -f log_data/nginx_logs/error.log
    b. Wordpressのログ
        i. tail -f log_data/wordpress_logs/access.log
        ii. tail -f log_data/wordpress_logs/error.log
        iii. tail -f log_data/wordpress_logs/other_vhosts_access.log
    c. ログ解析ツールの利用
        i. AWStats
        ii. Webalizer
            * sudo docker-compose exec webalizer webalizer /logs/access.log


b. "Google Analytics" プラグインの利用
    * 

c. "Jetpack" プラグインの利用
    * 

d. "WP Statistics" プラグインの利用
    * 

# License
This system is MIT licensed.
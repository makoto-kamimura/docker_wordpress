# Docker_WordPress
Wordpress環境簡易デプロイツール  
当ツールは、Dockerを用いて簡易的にWordPress環境を立ち上げるスクリプトツールです。  

# DEMO
 ※デモ画像等後程記載を予定

# Requirement
 ※バージョン等後程記載を予定
* Mac M1
    * Docker
        * WordPress
        * MySQL
        * SSL_certs(予定)

# Installation
Local deploy
1. Git clone https://github.com/makoto-kamimura/Docker_WordPress.git
2. "docker-compose.yml"の存在するディレクトリまで移動
3. "docker-compose down -v && docker-compose build && docker-compose up -d"をターミナルにて実行
4. "localhost:8000"をブラウザにて入力/実行

# Note

# License
This system is MIT licensed.

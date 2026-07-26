Cloudflare API v4 Dynamic DNS Update in Bash, without unnecessary requests
Now the script also supports v6(AAAA DDNS Recoards)

下载cf-v4-ddns.sh,编辑一下加到crontab里

sudo wget https://raw.githubusercontent.com/socosfly/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh -O /usr/local/bin/cf-ddns.sh
sudo chmod +x /usr/local/bin/cf-ddns.sh
sudo nano /usr/local/bin/cf-ddns.sh

修改default config下的几个配置变量

crontab -e
在最后加上*/2 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1
如果需要日志就换成这条*/2 * * * * /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1


import scrapy
import re
import os
import random
from scrapy.crawler import CrawlerProcess
from scrapy_selenium import SeleniumRequest
from scrapy_splash import SplashRequest
import time
from collections import defaultdict

def get_poc_tx():
    tx_set = defaultdict(set)
    no_tx_set = []
    
    for root, dirs, files in os.walk("/home/zp9080/Code/DeFiHackLabs/src/test"):
        for file in files:
            file_path = os.path.join(root, file)
            with open(file_path, "r") as f:
                for line in f.readlines():
                    if "tx/" in line:
                        tx_value = next((p.strip()[:66] for p in line.split("/") if p.strip().startswith("0x")))
                        tx_set[file_path].add(tx_value)
                # 判断集合是否为空
                if not tx_set[file_path]:  # 等价于 len(tx_set[file_path]) == 0
                    no_tx_set.append(file_path)
    
    return tx_set, no_tx_set


# 定义 Scrapy 爬虫
class mySpider(scrapy.Spider):
    name = "myspider"
    allowed_domains = ["app.blocksec.com"] 
    def start_requests(self):
        # 随机 User-Agent 列表
        user_agents = [
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15'
        ]
        # 随机选择 User-Agent 和代理
        headers = {
            "Host": "app.blocksec.com",
            "User-Agent": random.choice(user_agents),  # 需预定义user_agents列表
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            # "Accept-Encoding": "gzip, deflate, br",
            "Referer": "https://app.blocksec.com/",
            "Origin": "https://app.blocksec.com",
            "Connection": "keep-alive",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "cross-site",
            "Upgrade-Insecure-Requests": "1"
        }
            
	
        proxies = {
            'http': 'http://127.0.0.1:7890',
            'https': 'http://127.0.0.1:7890'
        }
        
        cookies={
            "_ga": "GA1.1.767266128.1741076513",
            "_ga_NX4R0V8PLF": "GS1.1.1741076513.1.0.1741076513.0.0.0",
            "cf_clearance": "FdsWEDWtxS1f_Pz.d29qOrCt13XKO6ZN7bJEvWzhugA-1741077033-1.2.1.1-B2Gd2QHFmbbaT7pmgZMOsAOZYZP1uJhyMyyrJEESfZ_GSih8VTxTDM_l_aZTDaU3vGl_FB37k55QW_n8QtbzBpFYcUpUZC_u_sY2uGqXUI9uvmfTkIgYtqsJH_t5mApe8myyPUtjMMmZNGKfS3BiQmGgXPNEhV1ZSbHN1kWVfyo3xVWMHBmz28_Q5Sa4YY2xcqylz6L3jOvdb.3RN9c1pmdkbXKEpheTpKBnwkc.Ytiip6phFhHeYKBBYQydk9MtRsXmRj2o2kHSTt7OuD7VQmMVUXaNZLNUKcpu9oPxCMAMA8VAAa9vd.l1wHBwf9Spn3ZLRGwZXykx6uQha9XC8yCGQkUrK0971SqRHzwpS9QarvBbXHL8jw0BhRLp2p2EpIZSXhuqn5uWs7tShElZDOr0k.1Dr.kh_MxclYo7Ans"
        }


        # 对当前文件的 address_map 生成请求

        source=["eth","bsc","optimism"]
        tx_set,no_tx_set=get_poc_tx()
        for k, v in tx_set.items():
            if v:
                for address in v:
                    for sc in source:
                        url = f"https://app.blocksec.com/explorer/tx/{sc}/{address}"
                        # proxy = proxies.get('https', proxies.get('http'))
                        # 生成 0 到 2 秒之间的随机延迟
                        delay = random.uniform(1, 1.5)  
                        print(f"Sleeping for {delay} seconds")
                        self.logger.info("Request for %s", url)
                        time.sleep(delay)
                        yield SplashRequest(
                            url,
                            headers=headers,
                            cookies=cookies,
                            meta={"file_path":k},
                            dont_filter=True, 
                            callback=self.parse
                        )
    def parse(self, response):
        if response.status != 200:
            self.logger.warning(f"无效响应：{response.url} (状态码 {response.status})")
            return
        # Scrapy中获取文本的正确方式
        print(type(response))  # 输出应为TextResponse或其子类（如HtmlResponse）
        print(response.url,response.body)
        input("Press Enter to continue...\n")
        # filename=os.path.basename(response.meta["file_path"])
        # output_filepath=os.path.join("/home/zp9080/Code/tx-anomaly-predict/zp9080/Invocation-Flow-Set",filename)+".txt"
        # with open(output_filepath, "ab") as f:
        #     f.write(response.body)
        # self.logger.info(f"成功写入文件：{output_filepath} | 来源URL:{response.url}")


if __name__ == "__main__":
    # 配置并启动 Scrapy 爬虫
    process = CrawlerProcess()
    process.crawl(mySpider)
    process.start()
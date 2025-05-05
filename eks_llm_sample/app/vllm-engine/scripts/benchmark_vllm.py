import aiohttp
import asyncio
from aiohttp import ClientTimeout
import time
import json
import random


url = "http://vllm-engine-qwen-14b-chat.yugaozh-flow.com/v1/chat/completions"
# url = "http://vllm-engine-rose-20b-awq.yugaozh-flow.com/v1/chat/completions"

headers = {
    'Content-Type': 'application/json',
}

prompts = ['小明', '小李', '小王', '张三', '李四', '王五', '小六', '赵四', '李哥', '朱姐',
            '沐宸', '浩宇', '沐辰', '茗泽', '奕辰', '宇泽', '浩然', '奕泽', '宇轩', '沐阳',
            '袁广瑗', '和明澜', '俞谦勇', '赵婉榕', '郑树莉', '蒯梅凝', '咸婷震', '王亚融', '傅清彩', '钱钧菊',
            '储青蓉', '喻航美', '莘茗丹', '钟凡军', '柯蓓琼', '程海壮', '狄博超', '杨希辉', '叶毓咏', '倪敬厚',
            '方莲宁', '扈时全', '费雅生', '邬行媛', '张河兴', '习亮瑾', '宰乐滢', '毛影志', '宓义功', '雷慧泰',
            '莫苑磊', '史海磊', '幸欣超', '喻心秋', '龙光和', '耿先亨', '甄厚希', '戚波世', '唐洁莎', '广德璐',
            '乔丽义', '昌寒致', '冉兰功', '曾影鸣', '那俊绍', '伍昭利', '司爱顺', '闵红龙', '陆仁翠', '越梁琬',
            '范思奇', '陈时飞', '盛盛栋', '景晓彪', '夏克春', '朱凝秀', '巴杰松', '从薇云', '元才利', '奚中育',
            '段嘉荔', '曲楠丹', '历艳风', '游淑祥', '喻黛华', '敖珊雅', '容俊贞', '蔺以建', '关学伯', '聂绍昭',
            '颜桂馥', '胥月娜', '殳梦群', '养富心', '常鹏倩', '边昌中', '胡瑗钧', '朱亨亚', '水时莲', '房强柔',
            '沙宁刚', '贡彩茜', '项菁惠', '都滢可', '艾善融', '单新健', '庾彪力', '寇发亮', '赵思婷', '楚心飘',
            '湛姬世', '谷超承', '廉英行', '夔裕纨', '师梦明', '范维君', '庾峰中', '葛琼可', '贾茜宁', '权雁梁',
            '侯芬惠', '郜固进', '梅竹星', '贺冠雅', '戎致馥', '伍良露', '缪盛咏', '莫风颖', '相伯雪', '田胜霞',
            '金力春', '平娥厚', '高澜若', '栾钧岚', '冀茂荣', '苏枫纯', '云辰琦', '昌冰义', '邴晨荔', '荣勇家',
            '柳瑶顺', '狄泽林', '易丽勇', '游兴慧', '宿纨言', '束琳育', '盍辉悦', '刁媛娟', '傅艺羽', '纪琰竹',
            '时武眉', '曹雅芝', '姜敬策', '陈启伟', '钮琴民', '艾平欣', '米凝鸣', '严邦斌', '梁淑卿', '酆善江',
            '家菲艺', '解时波', '卞燕锦', '段利明', '孔平学', '庾伊龙', '干霭滢', '黄文宁', '简旭亚', '侯慧涛',
            '党龙滢', '雍勇茂', '东澜环', '叶彬河', '谷福钧', '姜惠昭', '郎冰馨', '逄良俊', '诸利奇', '崔斌素',
            '曾芸宏', '支芳东', '咸诚淑', '岑绍媛', '宦琳林', '昌武生', '于宁怡', '敖风毅', '堵辉全', '薛刚腾',
            '尤妹浩', '邵平晨', '和世超', '糜达光', '沙勤岩', '司纯飞', '瞿才艺', '空以中', '唐文梁', '贾瑶天',
            '康超壮', '滑淑梦', '和群树', '韶静生', '昝颖飞', '汲翔中', '鱼荔伟', '后志婵', '蓟雁朗', '符凤宁',
            '竺保澜', '梅香弘', '乐韵琬', '茅馨馥', '安栋荷', '吕君珠', '华风琛', '郑艳思', '逄蓉庆', '茹强希',
            '祁安妹', '张娜鸣', '项美园', '俞雅裕', '于枫融', '裘德海', '钮玲珊', '糜发民', '阮功鸣', '慎菲贵',
            '翟伊欢', '毛浩朋', '元璐思', '耿翠安', '尹霞光', '计珠钧', '柳克爽', '隆泽彩', '易伯倩', '江君彬',
            '宿富言', '祁琳绍', '逄伦云', '申媛毓', '傅楠妹', '鄂琰磊', '时露眉', '宗雅滢', '姜纯策', '霍克宏',
            '钮昌友', '杭颖乐', '米芬鸣', '宣邦婉', '梁希卿', '储厚桂', '家超兰', '瞿时德', '卞进锦', '师利珍'
            ]

results = list()


def _generate_perf_report(outputs, start_time):
    total_tokens = 0
    total_prompt_tokens = 0
    total_completion_tokens = 0
    
    for output in outputs:
        total_tokens += output['usage']['total_tokens']
        total_prompt_tokens += output['usage']['prompt_tokens']
        total_completion_tokens += output['usage']['completion_tokens']
        
    spend_time = round(time.time() - start_time, 2)

    print(f"Total requests          : {len(outputs)}")
    print(f"Total tokens            : {total_tokens}")
    print(f"Total prompt tokens     : {total_prompt_tokens}")
    print(f"Total completion tokens : {total_completion_tokens}")
    
    print(f"Total spend time        : {spend_time} seconds")
    print(f"Completion generation   : {round(total_completion_tokens/spend_time, 2)} tokens/second.")
    print(f"Total generation        : {round(total_tokens/spend_time, 2)} tokens/second.")
        
    return total_tokens, total_prompt_tokens, total_completion_tokens


async def benchmark():
    

    # 1. Generation
    timeout = ClientTimeout(total=120)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        try:
            index = random.randint(0, len(prompts) - 1)
            # print(index)
            # print(prompts[index])

            body = {
                "model": "qwen",
                # "model": "/home/app/vllm-engine/models/Rose-20B-AWQ",
                "messages": [
                    {
                        "role": "user",
                        "content": prompts[index] + ", 你好，讲个故事, 是小朋友喜欢听的主题, 长度大概在500字以内."
                    }
                ],
                "temperature": 0.7,
                "top_k": 1,
                "top_p": 0.95
            }
            async with session.post(url, headers=headers, json=body) as response:
                result = await response.text()
                results.append(json.loads(result))
                # print(f'version : {response.version}')
                # print(f'status  : {response.status}')
                # print(f'reason  : {response.status}')
                # print(f'ok      : {response.ok}')
                # print(f'method  : {response.method}')
                # print(f'url     : {response.url}')
                # print(f'real_url: {response.real_url}')
                # print(f"result  :{result}")
        except ValueError as e:
            print(f'ValueError  : {e}')
        except aiohttp.InvalidURL as e:
            print(f'InvalidURL  : {e}')
        except aiohttp.ClientError as e:
            print(f'ClientError : {e}')
        except aiohttp.ServerTimeoutError as e:
            print(f'ServerTimeoutError : {e}')
        except Exception as e:
            print(f'Exception   : {e}')    


async def main():
    for i in range(2):
        print('#' * 100)
        print(f'Benchmark test - round {i+1}')
        start_time = time.time()
        await asyncio.gather(*[benchmark() for i in range(300)])
        _generate_perf_report(results, start_time)
        results.clear()


asyncio.run(main())

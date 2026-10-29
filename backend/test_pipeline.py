from margin.pipeline import best_passages, norm, quote_found

src = norm("Brain imaging shows that virtually all regions of the brain are active over a day. The 10% myth is false.")
assert quote_found("virtually all regions of the brain are active over a day", src)
assert quote_found("Brain imaging shows that … are active over a day.", src)
assert not quote_found("only 10% of the brain is ever active", src)
assert not quote_found("short", src)
assert best_passages("cats are nice and fluffy animals indeed, everyone agrees on that one\nthe human brain uses far more than ten percent of its neurons daily",
                     "humans use 10% of their brain", n=1)[0].startswith("the human brain")
print("ok")

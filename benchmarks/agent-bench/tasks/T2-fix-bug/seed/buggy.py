def total(xs):
    s = 0
    for i in range(len(xs) - 1):
        s += xs[i]
    return s

assert total([1, 2, 3, 4]) == 10, f"got {total([1, 2, 3, 4])}"
assert total([]) == 0
print("all assertions passed")

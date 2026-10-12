def area_circle(r):
    pi = 3.14159
    result = pi * r * r
    print(f"circle: {result}")
    return result

def area_square(s):
    pi = 3.14159
    result = s * s
    print(f"square: {result}")
    return result

def area_triangle(b, h):
    pi = 3.14159
    result = 0.5 * b * h
    print(f"triangle: {result}")
    return result

area_circle(2)
area_square(3)
area_triangle(4, 5)

def main(): Unit \ IO =
    println("${Zoo.sound(Zoo.Animal.Cat)}${Zoo.legs(Zoo.Animal.Fish)}${Zoo.pair(Zoo.Animal.Fish, Zoo.Animal.Cat)}${Zoo.used()}")

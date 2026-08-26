(ns app.score.bitwig.protocol
  (:require [clojure.string :as str]))

(def ^:private virtual-midi
  #"^/vkb_midi/(\d+)/(note|drum|cc|aftertouch)/(\d+)$")

(def ^:private clip-launch
  #"^/track/(\d+)/clip/(\d+)/launch$")

(defn- first-int [arguments]
  (let [value (first arguments)]
    (cond
      (number? value) (long value)
      (string? value) (parse-long value)
      :else 0)))

(defn decode
  "Decode Score's OSC vocabulary into a compact Java Object[]."
  [address arguments]
  (let [value (first-int arguments)]
    (if-let [[_ channel kind number] (re-matches virtual-midi address)]
      (object-array [kind (dec (parse-long channel)) (parse-long number) value])
      (if-let [[_ track scene] (re-matches clip-launch address)]
        (object-array ["clip" (dec (parse-long track)) (dec (parse-long scene)) value])
        (case address
          "/stop" (object-array ["stop" 0 0 1])
          "/playbutton" (object-array ["play" 0 0 value])
          "/record" (object-array ["record" 0 0 1])
          "/repeat" (object-array ["loop" 0 0 value])
          "/click" (object-array ["click" 0 0 value])
          "/undo" (object-array ["undo" 0 0 1])
          "/redo" (object-array ["redo" 0 0 1])
          "/project/save" (object-array ["save" 0 0 1])
          "/action" (object-array ["action" 0 (dec value) 1])
          "/refresh" (object-array ["refresh" 0 0 1])
          nil)))))

(defn describe [address arguments]
  (str address " " (str/join " " (map pr-str arguments))))

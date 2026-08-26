(ns app.score.bitwig.protocol-test
  (:require [app.score.bitwig.protocol :as protocol]
            [clojure.test :refer [deftest is run-tests]]))

(deftest decodes-score-controller-messages
  (is (= ["note" 0 36 104]
         (vec (protocol/decode "/vkb_midi/1/note/36" [104]))))
  (is (= ["aftertouch" 4 48 76]
         (vec (protocol/decode "/vkb_midi/5/aftertouch/48" [76]))))
  (is (= ["clip" 2 3 1]
         (vec (protocol/decode "/track/3/clip/4/launch" [1]))))
  (is (= ["play" 0 0 1]
         (vec (protocol/decode "/playbutton" [1]))))
  (is (nil? (protocol/decode "/unknown" []))))

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'app.score.bitwig.protocol-test)]
    (System/exit (if (zero? (+ fail error)) 0 1))))

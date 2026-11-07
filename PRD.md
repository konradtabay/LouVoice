Problem:
Imagine: You have been a teacher for several years. You love interacting with students, and after long days at work, nothing brings you more joy than chatting with your partner and kids. But one day, your voice starts to fatigue. You struggle to articulate the words that used to come naturally.When the diagnosis for ALS comes, your whole life turns upside down. Suddenly, talking goes from something you used to love, to something you dread. As time goes by, it becomes harder and harder to form sentences, and you begin to feel disconnected from those around you. 

User(s): Unfortunately, this is one of the most common problems that people with ALS face. According to a 2011 review by Beukelman, Fager and Nordness (published in Neurology Research International and hosted on the NIH's PubMed Central), at some point 80 to 95% of people with ALS are unable to meet their daily communication needs using natural speech. Losing your ability to communicate doesn’t just make it harder for caretakers to understand your needs, it removes the very connection that you have with the people around you. Something as simple as telling your family you love them becomes an arduous task. Modern day eye-tracking technologies take far too long to generate sentences, which completely takes the user out of conversations and makes it seem artificial and non-human. 

Who LouVoice is for: people whose speech is getting slower or harder to understand, but who can still move their jaw the same way each time they say a word. ALS weakens the same jaw, lip and tongue muscles that LouVoice reads, so LouVoice works best when someone enrolls early, while those movements are still strong. Alex can still speak today, which makes now the best time for him to start.

Our Solution + Core Loop: ElevenLabs(the world’s premier voice AI company) already has their impact program, that allows people with neurodegenerative diseases to create free clones of their voice, but the users still have to type words in to get the AI to speak them, which removes the personal element to a conversation because they have to actively type out their responses each time. The process is time consuming and artificial. 
LouVoice changes that. By using the built in sensors of standard Airpods, LouVoice tracks facial muscle movement and gets trained on the specific patterns that people use for words. Once that data is collected, simply moving your mouth will generate words on the dashboard that are read aloud by the ElevenLabs voice clone in your unique voice. 

How it works: 
Get set up. All you need is a pair of AirPods Pro 2 and a Mac. No special medical hardware.
Create your voice. LouVoice builds a copy of your voice with ElevenLabs. (See Where your voice comes from below.)
Teach LouVoice your words. Pick the words and phrases that matter most to you, like “I love you,” “how was your day,” or your kids’ names. Mouth each one a few times while wearing your AirPods. A first round of training takes about 10 minutes.
Start talking. Mouth a word or phrase, and LouVoice shows it on screen and says it out loud in your own voice.
Fix it in one tap. If LouVoice guesses wrong, you or a caregiver pick the right word from its top guesses. Every fix teaches it to do better next time.
Grow with you. As your movements change, LouVoice notices which words are slipping and asks you to retrain just those, not start over.


Building for patient’s needs: Deterioration over time is one of the biggest issues with ALS, so we want LouVoice to be able model the way your patterns change over time and adapt accordingly. This isn’t just a one-time use product, we want users to be able to use LouVoice for as long as they possibly can so that they can preserve their connections as long as possible.

The physical limit: retraining can follow movements as they weaken, but only while they stay repeatable. Once the jaw can no longer move the same way twice, there is no pattern left for LouVoice to learn. Decline can also be fast: Beukelman et al. found that once intelligibility begins to decrease, speech performance often deteriorates so rapidly that there is little time to set up another way to communicate. LouVoice handles this in three ways:
Enroll early. Training starts while movements are strong, so the model has a clean baseline to adapt from.
Track and retrain word by word. Tiger Data stores each user's movement strength and per-word accuracy over time. When one word starts slipping, LouVoice asks the user to retrain just that word instead of starting over.
Be honest when the signal fades. When movements become too weak to read reliably, LouVoice tells the user and their caregiver so they can plan the move to another communication method in time, instead of letting the app silently guess wrong.

Where your voice comes from:

LouVoice speaks in your voice, not a robotic one, and there are two ways to get it.
If you can still speak: this is the best time to start. While you train LouVoice, you say each word out loud, and LouVoice records your voice at the same time. One session teaches LouVoice your movements and saves your voice for the future. If you’ve already lost some or all of your speech: your voice can be rebuilt from old recordings, like home videos, voicemails or recorded speeches. Family members can help find them. Through the ElevenLabs Impact Program, people living with ALS can get their voice clone for free.

For caregivers:
LouVoice is built for the person using it, but caregivers can help make it work day to day. Caregivers can: Help with setup: putting in the AirPods, creating the voice, and running the first training session. Turn listening on and off, so LouVoice only speaks when it’s meant to.
Fix wrong words with one tap when the user can’t.
Get early warnings. If LouVoice sees movements getting too weak to read reliably, it tells both the user and the caregiver, so there’s time to plan the next way to communicate together.

Privacy and your data:

Your voice and your movements are personal health information, and we treat them that way. 
Stays on your Mac: your raw movement data and your trained model.
Goes to ElevenLabs: your voice recordings, only to create your voice clone.
Goes to our servers only if you say yes: summary numbers about how your movements change over time (how strong they are, how accurate each word is), stored with Tiger Data to help LouVoice adapt to you.
You’re in control: you can see what’s been shared and delete all of it at any time.
LouVoice is a student project and hasn’t been through formal health-privacy certification yet.

What LouVoice is not:
Not a medical device. It hasn’t been clinically tested or approved, and it doesn’t replace a communication assessment from your ALS clinic or speech-language pathologist.
Not mind-reading or open-ended speech. LouVoice only knows the words and phrases you’ve taught it.
Not forever. LouVoice works as long as your mouth movements stay consistent. When they don’t, it will tell you honestly rather than guess.

What you need
AirPods Pro 2 (the model we’ve tested)
A Mac running macOS 14 or newer
An internet connection to set up your voice and to sync your progress (optional)
About 10 minutes for your first training session
Success test: For our MVP to be considered a success, the judge or the user should be able to speak each word to whatever their ability and train the model on that pattern. Once trained, the user mouths a full sentence and the ElevenLabs reads the words aloud with less than 1.5 seconds of delay. The product must feel conversational and real, not artificial, because that removes the very connection we are trying to preserve.

How we measure it:
Accuracy: word accuracy on a session the model never trained on. Today: 49% (default) to 68% (tuned) on 5 words, against 20% chance. Target: 90% or higher.
Delay: time from the end of a mouthed word to the start of audio. Target: under 1.5 seconds.
Sentence success: share of full sentences read out correctly. Today: about 15% for a 5-word sentence at 68% word accuracy.


Biggest risks: The patient/user is unable to produce consistent movements for words so the model has to guess and get it wrong. The AI takes too long to read each word outloud, making it feel artificial. The model only registers one word at a time, so trying to speak a full sentence takes too long or doesn’t come out cleanly.

Future developments: Use the generated text to be inputted into messages so the product works in the reverse: for people that have lost muscle function in their hands(cant type) but still have some voice capabilities.

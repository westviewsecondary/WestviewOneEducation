import {uid,today,buildRooms,HOUSES,createClasses,generateTimetables,importStudents} from './core.mjs';
export function initialState(){
 const s={version:1,school:{name:'Westview Secondary',year:'2026/27',status:'open',reason:''},houses:HOUSES,tutors:[],teachers:[],rooms:buildRooms(),classes:[],students:[],attendance:[],points:[],incidents:[],removals:[],closures:[],cycles:[],exams:[],covers:[],announcements:[],audit:[]};
 const tutorNames=['11MWR','11GLK','11TRS','11RJN'];const teachers=['Mr M. Williams','Ms G. Clarke','Mr T. Shah','Ms R. Jones'];
 tutorNames.forEach((name,i)=>{const teacher={id:uid(),name:teachers[i],department:'Pastoral'};s.teachers.push(teacher);s.tutors.push({id:uid(),name,year:11,teacherId:teacher.id,roomId:s.rooms[i].id,capacity:32,description:'Year 11 tutor community'})});
 createClasses(s,{year:11,sets:5,mode:'all'});generateTimetables(s);
 const first=['Amelia','Oliver','Isla','Noah','Freya','Leo','Ava','George','Maya','Theo','Sofia','Arthur','Grace','Oscar','Evie','Muhammad','Lily','Henry','Zara','Alfie','Florence','Ethan','Poppy','Isaac','Mia','Lucas','Alice','Archie','Ruby','Jack','Ivy','Joshua','Esme','Finley','Daisy','Adam','Sienna','Hugo','Ella','Jude','Willow','Ayaan','Chloe','Toby','Layla','Thomas','Elsie','Max','Harper','Daniel','Phoebe','Reuben','Nora','Reggie','Aisha','Dylan','Rose','Benjamin','Imogen','Louis','Matilda','Yusuf','Lucy','William','Millie','Harrison','Erin','Edward','Hannah','Nathan','Amber','Samuel'];
 const last=['Bennett','Patel','Wilson','Taylor','Ahmed','Clarke','Morgan','Davies','Roberts','Shah','Lewis','Walker','Khan','Reed','Cooper','Hughes','Hall','Foster','Singh','Brooks','Green','Evans','Thomas','Williams'];
 for(let g=0;g<3;g++)importStudents(s,first.slice(g*24,g*24+24).map((name,i)=>({first:name,last:last[(i+g*7)%last.length]})),11,s.tutors[g+1].id);
 s.announcements.push({id:uid(),scope:'school',groupId:'',title:'Welcome to your Year 11 workspace',body:'Your school day, students and teaching groups are all connected here.\n\nYear 11 tutors can use their community to share notices and exam information.',date:today()});
 for(const t of s.tutors.filter(t=>t.name!=='11MWR'))s.announcements.push({id:uid(),scope:'tutor',groupId:t.id,title:'A good start to the school day',body:'Please arrive for tutor time at 08:25 with your equipment. Check this community for tutor notices.',date:today()});
 return s;
}
